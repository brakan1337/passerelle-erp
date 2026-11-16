use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode ();
use Test::More;
use Passerelle::Copybook qw(lire_copybook);
use Passerelle::Decodage qw(decoder_enregistrement decoder_nombre en_decimal en_francais);
use Passerelle::Fabrique qw(apport surfrappe);
use Passerelle::Csv qw(ligne_csv);

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my %sans_signe  = (signe => 'aucun');
my %inclus      = (signe => 'inclus', position => 'fin');
my %separe      = (signe => 'separe', position => 'fin');
my %separe_tete = (signe => 'separe', position => 'debut');

sub nombre { my ($champ, $texte) = @_; return [ decoder_nombre($champ, $texte) ] }

# --- Nombres ------------------------------------------------------------------

is_deeply(nombre(\%sans_signe, '012450'), [ 12450, undef ], 'zéros de tête');
is_deeply(nombre(\%sans_signe, '000000'), [ 0, undef ], 'zéro');
is_deeply(nombre(\%sans_signe, '      '), [ undef, 'champ numérique vide' ], 'blancs : champ vide');
is_deeply(nombre(\%sans_signe, "\0\0\0"), [ undef, 'champ numérique vide' ], 'LOW-VALUES : champ vide');
is_deeply(nombre(\%sans_signe, '12 4O0'), [ undef, 'pas un nombre' ], 'lettre O au lieu d\'un zéro');
is_deeply(nombre(\%sans_signe, '-00012'), [ undef, 'pas un nombre' ], 'signe dans un champ non signé');

# Signe inclus : chaque lettre de la table, positive et négative.
my @positifs = ('{', 'A' .. 'I');
my @negatifs = ('}', 'J' .. 'R');
for my $chiffre (0 .. 9) {
    is_deeply(nombre(\%inclus, "0001$positifs[$chiffre]"), [ 10 + $chiffre, undef ], "« $positifs[$chiffre] » vaut +$chiffre");
    is_deeply(nombre(\%inclus, "0001$negatifs[$chiffre]"), [ -(10 + $chiffre), undef ], "« $negatifs[$chiffre] » vaut -$chiffre");
}
is_deeply(nombre(\%inclus, '0001r'), [ -12, undef ], 'négatif à la Micro Focus');
is_deeply(nombre(\%inclus, '00015'), [ 15, undef ], 'un chiffre ordinaire vaut positif');
is_deeply(nombre(\%inclus, '0000}'), [ 0, undef ], 'moins zéro vaut zéro');
is_deeply(nombre({ signe => 'inclus', position => 'debut' }, 'J0002'), [ -10002, undef ], 'signe inclus en tête');
is(surfrappe(-1234, 9), '00000123M', 'la fabrique écrit le signe comme l\'ERP');
is_deeply(nombre(\%inclus, surfrappe($_, 9)), [ $_, undef ], "aller-retour de $_") for (-999_999_999, -1, 0, 7, 447_125);

# Signe séparé.
is_deeply(nombre(\%separe, '00000012345+'), [ 12345, undef ], 'signe + à droite');
is_deeply(nombre(\%separe, '00000012345-'), [ -12345, undef ], 'signe - à droite');
is_deeply(nombre(\%separe_tete, '-0012'), [ -12, undef ], 'signe - à gauche');
is_deeply(nombre(\%separe, '00000012345 '), [ undef, 'signe absent, + ou - attendu' ], 'signe effacé');
is_deeply(nombre(\%separe, '000000123450'), [ undef, 'signe « 0 » invalide, + ou - attendu' ], 'signe décalé');

# --- Mise en forme décimale --------------------------------------------------

is(en_decimal(447125, 2), '4471.25', 'centimes');
is(en_decimal(-21900, 2), '-219.00', 'avoir');
is(en_decimal(5, 2),      '0.05',    'moins d\'un euro');
is(en_decimal(-5, 2),     '-0.05',   'moins d\'un euro, négatif');
is(en_decimal(0, 2),      '0.00',    'zéro');
is(en_decimal(145, 1),    '14.5',    'une décimale');
is(en_decimal(24500, 0),  '24500',   'aucune décimale');
is(en_decimal(99_999_999_999, 2), '999999999.99', 'grand total exact');
is(en_francais(-1234, 2), '-12,34', 'virgule pour les messages');

# --- Un enregistrement complet ------------------------------------------------

my $format = lire_copybook("$FindBin::Bin/../formats/apports.cpy");
my $L      = $format->{enregistrements}{L};
my $cp850  = Encode::find_encoding('cp850');

my ($v, $b, $e) = decoder_enregistrement($L, apport(bon => 42, nom => 'GAEC DES PRÉS', avoir => 1, poids => 1200), $cp850);
is_deeply($e, [], 'aucune erreur');
is($v->{'NUM-BON'}, 42, 'valeur numérique');
is($b->{'NUM-BON'}, '00000042', 'texte d\'origine gardé : les numéros gardent leurs zéros');
is($v->{'NOM-ADHERENT'}, 'GAEC DES PRÉS', 'texte CP850 décodé, blancs de fin retirés');
is($v->{MONTANT}, -21900, 'avoir de 219,00 €');
is($v->{HUMIDITE}, 145, 'humidité à l\'échelle du champ');
ok(!exists $v->{FILLER} && !exists $v->{ADHERENT}, 'ni FILLER ni groupe dans les valeurs');

my $ligne = apport();
substr($ligne, 16, 30, "GAEC\0\0\0" . (' ' x 23));
($v, $b, $e) = decoder_enregistrement($L, $ligne, $cp850);
is($v->{'NOM-ADHERENT'}, 'GAEC', 'LOW-VALUES dans un texte : traités comme des blancs');

substr($ligne, 16, 30, "GAEC\tDES PRES" . (' ' x 17));
($v, $b, $e) = decoder_enregistrement($L, $ligne, $cp850);
is_deeply($e, [ [ 'NOM-ADHERENT', 'caractère de contrôle 0x09 dans le texte' ] ], 'tabulation refusée');

$ligne = apport();
substr($ligne, 58, 6, '012O40');
substr($ligne, 73, 9, '         ');
($v, $b, $e) = decoder_enregistrement($L, $ligne, $cp850);
is_deeply($e, [ [ 'POIDS-KG', '« 012O40 » n\'est pas un nombre' ], [ 'MONTANT', 'champ numérique vide' ] ],
    'deux erreurs sur une ligne, chacune avec son champ');
ok(!exists $v->{'POIDS-KG'} && !exists $v->{MONTANT}, 'un champ illisible n\'a pas de valeur');

# --- CSV ---------------------------------------------------------------------

is(ligne_csv(',', 'a', 'b c', ''), "a,b c,\r\n", 'champs simples, fin de ligne CRLF');
is(ligne_csv(',', 'DUPONT, PÈRE', 'dit "le grand"', undef), qq("DUPONT, PÈRE","dit ""le grand""",\r\n),
    'séparateur et guillemets échappés');
is(ligne_csv(';', 'a,b', "deux\nlignes"), qq(a,b;"deux\nlignes"\r\n), 'la virgule ne compte qu\'avec le séparateur virgule');

done_testing;
