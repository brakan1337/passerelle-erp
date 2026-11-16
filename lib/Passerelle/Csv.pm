package Passerelle::Csv;

# Écriture CSV selon la RFC 4180 : guillemets autour des champs qui
# contiennent le séparateur, un guillemet ou un saut de ligne ; guillemets
# doublés ; lignes terminées par CRLF.

use 5.010_001;
use strict;
use warnings;
use utf8;

use Exporter 'import';

our @EXPORT_OK = qw(ligne_csv);

my %SPECIAUX;

sub ligne_csv {
    my ($separateur, @valeurs) = @_;
    my $special = $SPECIAUX{$separateur} //= qr/[\Q$separateur\E"\r\n]/;
    return join(
        $separateur,
        map {
                !defined $_    ? ''
              : !/$special/    ? $_
              : do { (my $echappe = $_) =~ s/"/""/g; qq("$echappe") }
        } @valeurs
    ) . "\r\n";
}

1;
