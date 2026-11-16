#!/usr/bin/env perl

# Génère un fichier d'export d'essai, au format et dans l'encodage de l'ERP.
#   perl outils/generer.pl --apports 40 --erreurs --sortie exemples/APP00412.DAT
# --erreurs glisse une faute de chaque sorte : clé d'adhérent, produit,
# date, humidité, montant, bon en double, poids illisible, nom vide.

use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Getopt::Long qw(GetOptions);
use Passerelle::Fabrique qw(ecrire_lot_aleatoire);

my %o = (apports => 1000, lot => 412, site => 'MONT', date => '20261116', graine => 412);
GetOptions(\%o, 'apports=i', 'lot=i', 'site=s', 'date=s', 'graine=i', 'erreurs', 'crlf', 'sortie=s')
  or die "Utilisation : generer.pl [--apports N] [--lot N] [--site CODE] [--date AAAAMMJJ] "
  . "[--graine N] [--erreurs] [--crlf] [--sortie FICHIER]\n";

my $fh;
if ($o{sortie}) {
    open $fh, '>:raw', $o{sortie} or die "Impossible d'écrire $o{sortie} : $!\n";
}
else {
    binmode STDOUT, ':raw';
    $fh = \*STDOUT;
}

my %options = %o;
delete @options{qw(crlf sortie)};
my $r = ecrire_lot_aleatoire($fh, %options, fin_ligne => $o{crlf} ? "\r\n" : "\n");
close $fh or die "Impossible d'écrire : $!\n";

binmode STDERR, ':encoding(UTF-8)';
printf STDERR "%d apports générés, dont %d avec une faute\n", $r->{apports}, $r->{fautes};
