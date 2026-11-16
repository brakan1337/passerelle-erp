use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode ();
use File::Spec;
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Symbol qw(gensym);
use Test::More;

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my $racine  = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $script  = File::Spec->catfile($racine, 'bin', 'passerelle');
my $exemple = File::Spec->catfile($racine, 'exemples', 'APP00412.DAT');

# Lance la commande, sans passer par un shell ; sorties standard et d'erreur mêlées.
sub lancer {
    my ($entree, $sortie) = (gensym, gensym);
    my $pid = open3($entree, $sortie, undef, $^X, $script, @_);
    close $entree;
    my $texte = do { local $/; <$sortie> };
    waitpid $pid, 0;
    return ($? >> 8, Encode::decode('UTF-8', $texte // ''));
}

my $dossier = tempdir(CLEANUP => 1);

my ($code, $texte) = lancer('--sortie', $dossier, $exemple);
is($code, 1, 'l\'exemple contient des rejets : code 1');
like($texte, qr/APP00412\.DAT : lot 000412 du site MONT, 40 apports lus, 32 acceptés, 8 rejetés/, 'bilan');
ok(-s File::Spec->catfile($dossier, 'apports_MONT_000412.csv'), 'apports écrits');
ok(-s File::Spec->catfile($dossier, 'rejets_MONT_000412.csv'), 'rejets écrits');

($code, $texte) = lancer('--sortie', $dossier, $exemple);
is($code, 0, 'second passage du cron : code 0');
like($texte, qr/déjà traité le .* \(lot MONT_000412\), ignoré/, 'et il le dit');

($code, $texte) = lancer('--sortie', $dossier, '--force', $exemple);
is($code, 1, '--force : retraité');

($code, $texte) = lancer('--aide');
is($code, 0, '--aide : code 0');
like($texte, qr/\AUtilisation : passerelle/, 'aide');

($code, $texte) = lancer();
is($code, 3, 'sans fichier : code 3');

($code, $texte) = lancer('--inconnue', $exemple);
is($code, 3, 'option inconnue : code 3');

($code, $texte) = lancer('--sortie', $dossier, '/nulle/part.DAT');
is($code, 3, 'fichier introuvable : code 3');
like($texte, qr/Fichier introuvable/, 'message clair');
unlike($texte, qr/ at \S+ line \d+/, 'sans trace interne de Perl');

($code, $texte) = lancer('--sortie', File::Spec->catdir($dossier, 'absent'), $exemple);
is($code, 3, 'dossier de sortie absent : code 3');

my $format = File::Spec->catfile($dossier, 'faux.cpy');
open my $fh, '>', $format or die $!;
print {$fh} "       01  R.\n           05  C PIC X VALUE 'R'.\n           05  M PIC S9(5) COMP-3.\n";
close $fh;
($code, $texte) = lancer('--format', $format, '--sortie', $dossier, $exemple);
is($code, 3, 'format invalide : code 3');
like($texte, qr/\Aerreur : .*faux\.cpy, ligne 3 : stockage « COMP-3 » non pris en charge/, 'le message nomme la ligne fautive');

done_testing;
