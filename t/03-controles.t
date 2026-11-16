use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode ();
use Test::More;
use Passerelle::Controles qw(controler_apport cle_luhn cle_luhn_valide date_valide en_iso date_fr montant_attendu);
use Passerelle::Copybook qw(lire_copybook);
use Passerelle::Decodage qw(decoder_enregistrement);
use Passerelle::Fabrique qw(apport);
use Passerelle::Lot qw(charger_produits);

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# --- Clé de Luhn ---------------------------------------------------------------

ok(cle_luhn_valide('79927398713'), 'exemple de référence de Luhn');
ok(!cle_luhn_valide('79927398710'), 'clé fausse');
is(cle_luhn('100001'), '1000017', 'clé calculée');
ok(!cle_luhn_valide('1000071'), 'deux chiffres inversés : détecté');
ok(!cle_luhn_valide(''),        'vide');
ok(!cle_luhn_valide('10O0017'), 'pas que des chiffres');

# --- Dates ---------------------------------------------------------------------

ok(date_valide('20240229'),  '29 février 2024 : bissextile');
ok(!date_valide('20230229'), '29 février 2023 : non');
ok(!date_valide('19000229'), '1900 n\'est pas bissextile');
ok(date_valide('20000229'),  '2000 l\'est');
ok(!date_valide('20261131'), '31 novembre');
ok(!date_valide('20261301'), 'mois 13');
ok(!date_valide('20260100'), 'jour 0');
ok(!date_valide('00000000'), 'date à zéro, laissée vide par l\'ERP');
is(en_iso('20261116'),  '2026-11-16', 'format ISO pour l\'outil de suivi');
is(date_fr('20261116'), '16/11/2026', 'format français pour les messages');

# --- Montant ---------------------------------------------------------------------

is(montant_attendu(24_500, 0, 18_250, 2, 2), 447_125, '24 500 kg à 182,50 €/t font 4 471,25 €');
is(montant_attendu(10, 0, 50, 2, 2), 1, 'un demi-centime s\'arrondit au centime supérieur');
is(montant_attendu(10, 0, 49, 2, 2), 0, 'en dessous, au centime inférieur');
is(montant_attendu(999_999, 0, 999_999, 2, 2), 999_998_000, 'le plus gros apport possible, exact');

# --- Règles d'un apport ------------------------------------------------------------

my $format   = lire_copybook("$FindBin::Bin/../formats/apports.cpy");
my $produits = charger_produits("$FindBin::Bin/../config/produits.csv");
my $L        = $format->{enregistrements}{L};
my $cp850    = Encode::find_encoding('cp850');
my %decimales = map { $_->{nom} => $_->{decimales} } grep { $_->{type} eq '9' } @{ $L->{champs} };

sub erreurs {
    my ($ctx, %apport) = @_;
    my ($v, $b, $e) = decoder_enregistrement($L, apport(%apport), $cp850);
    return [ @$e, controler_apport($v, $b, $ctx) ];
}

sub contexte {
    return { produits => $produits, date_export => '20261116', decimales => \%decimales, bons => {}, ligne => 7, @_ };
}

is_deeply(erreurs(contexte()), [], 'apport correct');
is_deeply(erreurs(contexte(), avoir => 1), [], 'avoir correct');
is_deeply(erreurs(contexte(), humidite => 350), [], 'humidité de 35 % : la limite passe');

is_deeply(erreurs(contexte(), adherent => '1000018'),
    [ [ 'NUM-ADHERENT', "clé de contrôle fausse pour l'adhérent 1000018" ] ], 'clé d\'adhérent');
is_deeply(erreurs(contexte(), nom => ''), [ [ 'NOM-ADHERENT', "nom d'adhérent vide" ] ], 'nom vide');
is_deeply(erreurs(contexte(), date => '20260230'), [ [ 'DATE-APPORT', 'date 20260230 impossible' ] ], 'date impossible');
is_deeply(erreurs(contexte(), date => '20261117'),
    [ [ 'DATE-APPORT', "apport daté du 17/11/2026, après l'export du 16/11/2026" ] ], 'date dans le futur');
is_deeply(erreurs(contexte(), produit => 'BLE'),
    [ [ 'CODE-PRODUIT', 'produit « BLE » absent du référentiel' ] ], 'produit inconnu');
is_deeply(erreurs(contexte(), poids => 0, montant => 0), [ [ 'POIDS-KG', 'poids nul' ] ], 'poids nul');
is_deeply(erreurs(contexte(), humidite => 412),
    [ [ 'HUMIDITE', 'humidité de 41,2 %, au-delà de 35 %' ] ], 'humidité');
is_deeply(erreurs(contexte(), montant => 447_225),
    [ [ 'MONTANT', 'montant de 4472,25 € au lieu de 4471,25 € (24500 kg à 182,50 €/t)' ] ], 'montant faux d\'un euro');
is_deeply(erreurs(contexte(), montant => 447_126), [], 'un centime d\'écart : toléré (arrondi de l\'ERP)');
is_deeply(erreurs(contexte(), montant => -447_225),
    [ [ 'MONTANT', 'montant de -4472,25 € au lieu de -4471,25 € (24500 kg à 182,50 €/t)' ] ], 'avoir faux');

my $ctx = contexte();
is_deeply(erreurs($ctx, bon => 12), [], 'premier bon 12');
$ctx->{ligne} = 9;
is_deeply(erreurs($ctx, bon => 12), [ [ 'NUM-BON', 'bon 00000012 déjà présent ligne 7' ] ], 'bon en double');

is_deeply(erreurs(contexte(), adherent => '1000018', produit => 'XXXX', humidite => 999),
    [ [ 'NUM-ADHERENT', "clé de contrôle fausse pour l'adhérent 1000018" ],
      [ 'CODE-PRODUIT', 'produit « XXXX » absent du référentiel' ],
      [ 'HUMIDITE',     'humidité de 99,9 %, au-delà de 35 %' ] ],
    'toutes les erreurs d\'une ligne, pas seulement la première');

done_testing;
