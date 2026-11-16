#!/usr/bin/env perl

# Mesure la vitesse de la passerelle sur un lot généré.
#   perl outils/banc.pl 1000000

use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use File::Spec;
use File::Temp qw(tempdir);
use Time::HiRes qw(time);

use Passerelle::Copybook qw(lire_copybook);
use Passerelle::Fabrique qw(ecrire_lot_aleatoire);
use Passerelle::Lot qw(traiter_fichier charger_produits);

binmode STDOUT, ':encoding(UTF-8)';

my $n = shift // 200_000;
die "Utilisation : banc.pl [NOMBRE_D_APPORTS]\n" if $n !~ /\A[0-9]+\z/ || $n < 1;

# Le total d'un lot tient dans S9(9)V99, moins d'un milliard d'euros :
# au-delà de 100 000 apports, on découpe en plusieurs lots, comme l'ERP.
my $PAR_LOT = 100_000;

my $racine  = File::Spec->catdir($FindBin::Bin, File::Spec->updir);
my $dossier = tempdir(CLEANUP => 1);
my $format   = lire_copybook(File::Spec->catfile($racine, 'formats', 'apports.cpy'));
my $produits = charger_produits(File::Spec->catfile($racine, 'config', 'produits.csv'));

my (@fichiers, $octets);
my $t0 = time;
for (my ($lot, $reste) = (1, $n); $reste > 0; $lot++, $reste -= $PAR_LOT) {
    my $fichier = File::Spec->catfile($dossier, sprintf 'APP%05d.DAT', $lot);
    open my $fh, '>:raw', $fichier or die "Impossible d'écrire $fichier : $!\n";
    ecrire_lot_aleatoire($fh, apports => ($reste < $PAR_LOT ? $reste : $PAR_LOT), lot => $lot, graine => $lot);
    close $fh;
    $octets += -s $fichier;
    push @fichiers, $fichier;
}
my $t1 = time;

for my $fichier (@fichiers) {
    my $r = traiter_fichier(fichier => $fichier, format => $format, produits => $produits, sortie => $dossier);
    die "Le banc attendait des lots sans rejet : $r->{fichier} a le code $r->{statut}\n" if $r->{statut} != 0;
}
my $t2 = time;

my $mo    = $octets / 1e6;
my $duree = $t2 - $t1;
printf "Perl %vd\n", $^V;
printf "%d apports en %d lots, %.1f Mo, générés en %.2f s\n", $n, scalar @fichiers, $mo, $t1 - $t0;
printf "convertis en %.2f s : %.0f apports par seconde, %.1f Mo/s\n", $duree, $n / $duree, $mo / $duree;
