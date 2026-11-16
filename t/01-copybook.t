use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Test::More;
use Passerelle::Copybook qw(lire_copybook analyser_copybook developper_pic);

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

# Écrit des lignes COBOL : 6 colonnes de séquence, l'indicateur, puis le code.
sub cobol { return join '', map { (' ' x 7) . "$_\n" } @_ }

sub erreur_de {
    my ($texte) = @_;
    eval { analyser_copybook($texte, 'essai.cpy') };
    return $@;
}

# --- Le format de l'ERP ---------------------------------------------------

my $f = lire_copybook("$FindBin::Bin/../formats/apports.cpy");
is_deeply($f->{ordre}, [qw(E L T)], 'trois enregistrements, dans l\'ordre du copybook');
is($f->{longueur_code}, 1, 'le code d\'enregistrement tient sur un caractère');
is($f->{enregistrements}{$_}{longueur}, 82, "enregistrement $_ : 82 caractères") for qw(E L T);

my $apport = $f->{enregistrements}{L};
is($apport->{nom}, 'APPORT', 'le code L désigne l\'enregistrement APPORT');
is($apport->{gabarit}, 'a1 a8 a7 a30 a8 a4 a6 a3 a6 a9', 'gabarit de découpe');

my $adherent = $apport->{par_nom}{'NUM-ADHERENT'};
is_deeply([ @$adherent{qw(debut longueur)} ], [ 9, 7 ], 'les champs du groupe ADHERENT sont aplatis à leur place');
ok(!$apport->{par_nom}{ADHERENT}, 'le groupe lui-même n\'occupe aucune place');
ok(!$apport->{par_nom}{AVOIR}, 'le niveau 88 est ignoré');

my $montant = $apport->{par_nom}{MONTANT};
is_deeply([ @$montant{qw(debut longueur entiers decimales signe position)} ],
    [ 73, 9, 7, 2, 'inclus', 'fin' ], 'MONTANT : signe porté par le dernier chiffre');

my $humidite = $apport->{par_nom}{HUMIDITE};
is_deeply([ @$humidite{qw(longueur entiers decimales signe)} ], [ 3, 2, 1, 'aucun' ], 'HUMIDITE : 9(2)V9');

my $total = $f->{par_nom}{'FIN-LOT'}{par_nom}{'TOTAL-MONTANT'};
is_deeply([ @$total{qw(debut longueur signe position)} ], [ 7, 12, 'separe', 'fin' ],
    'TOTAL-MONTANT : clause SIGN sur deux lignes, signe séparé à droite');

# --- PIC ------------------------------------------------------------------

is_deeply(developper_pic('X(4)'), { type => 'X', longueur => 4 }, 'X(4)');
is_deeply(developper_pic('xxx'),  { type => 'X', longueur => 3 }, 'XXX, en minuscules');
is_deeply(developper_pic('9(2)V9'),
    { type => '9', signe_pic => 0, entiers => 2, decimales => 1, longueur => 3 }, '9(2)V9');
is_deeply(developper_pic('S9(7)V99'),
    { type => '9', signe_pic => 1, entiers => 7, decimales => 2, longueur => 9 }, 'S9(7)V99');
like(eval { developper_pic('Z(5)9') } // $@, qr/non prise en charge/, 'PIC d\'édition refusée');
like(eval { developper_pic('9(16)') } // $@, qr/plus de 15 chiffres/, 'plus de 15 chiffres refusés');

# --- Mise en forme COBOL ----------------------------------------------------

# Colonnes 1-6 : séquence ; 7 : indicateur ; 8-72 : code ; 73-80 : identification.
sub carte { my ($seq, $ind, $code, $ident) = @_; return sprintf "%-6s%1s%-65s%s\n", $seq, $ind, $code, $ident // '' }
my $avec_marges = join '',
  carte('000100', ' ', '01  R.', 'IDENT001'),
  carte('000200', '*', 'un commentaire'),
  carte('000300', ' ', "    05  CODE PIC X VALUE 'R'.", 'IDENT002'),
  carte('000400', ' ', '    05  N    PIC S9(3)', 'IDENT003'),
  carte('000500', ' ', '             SIGN LEADING SEPARATE CHARACTER.');
my $m = analyser_copybook($avec_marges, 'marges.cpy');
my $n = $m->{enregistrements}{R}{par_nom}{N};
is($m->{enregistrements}{R}{longueur}, 5, 'numéros de séquence et zone d\'identification ignorés');
is_deeply([ @$n{qw(debut longueur signe position)} ], [ 1, 4, 'separe', 'debut' ], 'SIGN LEADING SEPARATE');

my $point = analyser_copybook(cobol("01 R.", "05 C PIC X VALUE '.'.", "05 V PIC 9 VALUE 0. 05 W PIC X."), 'p');
is($point->{enregistrements}{'.'}{longueur}, 3, 'un point entre quotes ne coupe pas l\'instruction ; deux instructions sur une ligne');

# --- Ce qui est refusé, et pourquoi ------------------------------------------

like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC S9(5) COMP-3.")),
    qr/COMP-3.*DISPLAY/, 'COMP-3 refusé, avec la solution');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC 9(5) USAGE IS BINARY.")),
    qr/BINARY/, 'USAGE BINARY refusé');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC 9 OCCURS 3.")),
    qr/OCCURS non prise en charge/, 'OCCURS refusé');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC 9.", "05 N REDEFINES M PIC X.")),
    qr/REDEFINES/, 'REDEFINES refusé');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'", "05 M PIC 9")),
    qr/non terminée par un point/, 'point final manquant');
like(erreur_de(cobol("01 R.", "05 C PIC X.", "05 M PIC 9.")),
    qr/doit porter le code/, 'premier champ sans VALUE');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "01 S.", "05 C PIC X VALUE 'R'.")),
    qr/deux enregistrements portent le code « R »/, 'code en double');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC 9(3) SIGN TRAILING SEPARATE.")),
    qr/pas de S/, 'SIGN sur un nombre sans S');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC 9.", "05 M PIC 9.")),
    qr/défini deux fois/, 'champ en double');
like(erreur_de(cobol("05 C PIC X VALUE 'R'.")), qr/hors de tout enregistrement/, 'champ sans 01');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R' JUSTIFIED.")), qr/JUSTIFIED/, 'JUSTIFIED refusé');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R' FOO.")), qr/clause inconnue « FOO »/, 'clause inconnue');
like(erreur_de(carte('', '*', 'que des commentaires')), qr/aucun enregistrement/, 'copybook vide');
like(erreur_de(cobol("01 R.", "05 C PIC X VALUE 'R'.", "05 M PIC Z9.")),
    qr/\Aessai\.cpy, ligne 3 : PIC Z9/, 'le message nomme le fichier et la ligne');

done_testing;
