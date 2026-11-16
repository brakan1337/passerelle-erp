use 5.010_001;
use strict;
use warnings;
use utf8;

use FindBin ();
use lib "$FindBin::Bin/../lib";

use Encode ();
use File::Spec;
use File::Temp qw(tempdir);
use Test::More;

use Passerelle::Controles qw(cle_luhn);
use Passerelle::Copybook qw(lire_copybook);
use Passerelle::Fabrique qw(entete apport fin lot assembler montant_de);
use Passerelle::Lot qw(traiter_fichier charger_produits);

binmode Test::More->builder->$_, ':encoding(UTF-8)' for qw(output failure_output todo_output);

my $format   = lire_copybook("$FindBin::Bin/../formats/apports.cpy");
my $produits = charger_produits("$FindBin::Bin/../config/produits.csv");

# Écrit le contenu (des octets) dans un dossier, et le passe dans la passerelle.
sub passer {
    my ($contenu, %o) = @_;
    my $dossier = delete $o{dossier} // tempdir(CLEANUP => 1);
    my $fichier = File::Spec->catfile($dossier, delete $o{nom} // 'APP00412.DAT');
    open my $fh, '>:raw', $fichier or die $!;
    print {$fh} $contenu;
    close $fh;
    my $sortie = File::Spec->catdir($dossier, 'sortie');
    mkdir $sortie if !-d $sortie;
    my $r = traiter_fichier(fichier => $fichier, format => $format, produits => $produits, sortie => $sortie, %o);
    return ($r, $sortie, $dossier);
}

sub lire {
    my ($chemin) = @_;
    open my $fh, '<:raw', $chemin or return;
    local $/;
    return Encode::decode('UTF-8', scalar <$fh>);
}

sub restes { my ($sortie) = @_; opendir my $d, $sortie or die $!; return grep { /\.part\z/ } readdir $d }

my $adherent = cle_luhn('100001');
my $entete   = "site,lot,num_bon,num_adherent,nom_adherent,date_apport,code_produit,produit,"
  . "poids_kg,humidite_pct,prix_tonne_eur,montant_eur\r\n";

# --- Un lot propre ------------------------------------------------------------

my $propre = lot(apports => [
    { bon => 10_000_001 },
    { bon => 10_000_002, nom => 'DUPONT, PÈRE ET FILS', produit => 'MAIS', humidite => 285 },
    { bon => 10_000_003, avoir => 1, poids => 1200 },
]);
my ($r, $sortie, $dossier) = passer($propre);
is($r->{statut}, 0, 'lot propre : code 0');
is_deeply([ @$r{qw(site lot apports_lus acceptes rejetes)} ], [ 'MONT', '000412', 3, 3, 0 ], 'bilan');
is(lire("$sortie/apports_MONT_000412.csv"), $entete
  . "MONT,000412,10000001,$adherent,GAEC DES PRÉS,2026-11-15,BLTE,Blé tendre,24500,14.5,182.50,4471.25\r\n"
  . "MONT,000412,10000002,$adherent,\"DUPONT, PÈRE ET FILS\",2026-11-15,MAIS,Maïs grain,24500,28.5,182.50,4471.25\r\n"
  . "MONT,000412,10000003,$adherent,GAEC DES PRÉS,2026-11-15,BLTE,Blé tendre,1200,14.5,182.50,-219.00\r\n",
  'CSV exact : UTF-8, dates ISO, point décimal, guillemets si besoin, avoir négatif');
ok(!-e "$sortie/rejets_MONT_000412.csv", 'pas de fichier de rejets quand tout passe');
like(lire("$sortie/.journal"), qr/\A[0-9a-f]{64}\t[0-9-]+ [0-9:]+\tAPP00412\.DAT\tMONT_000412\t3\t0\n\z/, 'journal');

# --- Déjà traité ----------------------------------------------------------------

($r) = passer($propre, dossier => $dossier, nom => 'COPIE.DAT');
ok($r->{deja}, 'même contenu sous un autre nom : reconnu');
is($r->{statut}, 0, 'et ignoré sans erreur');
is($r->{deja}{nom}, 'APP00412.DAT', 'on dit sous quel nom il a été traité');
($r) = passer($propre, dossier => $dossier, force => 1);
ok(!$r->{deja} && $r->{acceptes} == 3, '--force : retraité');

# --- Lignes rejetées ----------------------------------------------------------------

my $fautif = lot(apports => [
    { bon => 1 },
    { bon => 2, adherent => '1000018', produit => 'XXXX' },
    { bon => 3, humidite => 412 },
]);
($r, $sortie, $dossier) = passer($fautif);
is($r->{statut}, 1, 'lignes rejetées : code 1');
is_deeply([ @$r{qw(apports_lus acceptes rejetes)} ], [ 3, 1, 2 ], 'une ligne passe, deux sont rejetées');
my $rejets = lire("$sortie/rejets_MONT_000412.csv");
like($rejets, qr/\A\x{FEFF}fichier;ligne;num_bon;champ;motif;contenu\r\n/, 'rejets : BOM et point-virgule, pour Excel');
like($rejets, qr/^APP00412\.DAT;3;00000002;NUM-ADHERENT;clé de contrôle fausse/m, 'clé fausse, ligne 3');
like($rejets, qr/^APP00412\.DAT;3;00000002;CODE-PRODUIT;produit « XXXX »/m, 'même ligne, seconde erreur');
like($rejets, qr/^APP00412\.DAT;4;00000003;HUMIDITE;humidité de 41,2 %.*;L00000003/m, 'contenu brut de la ligne');
my $apports = lire("$sortie/apports_MONT_000412.csv");
is(scalar(() = $apports =~ /\r\n/g), 2, 'seul l\'apport correct part vers l\'outil de suivi');

# Le même lot, réexporté corrigé : les rejets de la veille disparaissent.
($r) = passer(lot(apports => [ { bon => 1 }, { bon => 2 }, { bon => 3 } ]), dossier => $dossier);
is($r->{statut}, 0, 'lot corrigé : code 0');
ok(!-e "$sortie/rejets_MONT_000412.csv", 'l\'ancien fichier de rejets est retiré');

# --- Lots refusés ----------------------------------------------------------------------

my $un  = apport(bon => 1);
my $m   = montant_de();
my %refus = (
    'fichier tronqué'          => [ assembler([ entete(), $un ]),                       qr/fichier tronqué/ ],
    'fichier vide'             => [ '',                                                 qr/aucun en-tête/ ],
    'nombre d\'apports faux'   => [ lot(apports => [ {}, { bon => 2 } ], fin => { nb => 3 }),
                                    qr/annonce 3 apports, le fichier en contient 2/ ],
    'total faux'               => [ lot(fin => { total => 1 }),
                                    qr/annonce un total de 0,01 €, les apports font 4471,25 €/ ],
    'données après la fin'     => [ $propre . "$un\n",                                  qr/données après la fin de lot/ ],
    'apport avant l\'en-tête'  => [ assembler([ $un, entete(), fin(1, $m) ]),           qr/apport avant l'en-tête/ ],
    'second en-tête'           => [ assembler([ entete(), entete(), $un, fin(1, $m) ]), qr/second en-tête/ ],
    'en-tête illisible'        => [ lot(entete => { date => '20261131' }),              qr/en-tête illisible : DATE-EXPORT/ ],
    'fin de lot illisible'     => [ assembler([ entete(), $un, 'T' . ('0' x 18) . ' ' x 63 ]),
                                    qr/fin de lot illisible : TOTAL-MONTANT : signe « 0 »/ ],
);
for my $cas (sort keys %refus) {
    my ($contenu, $motif) = @{ $refus{$cas} };
    ($r, $sortie) = passer($contenu);
    is($r->{statut}, 2, "$cas : lot refusé, code 2");
    like($r->{refus}, $motif, "$cas : motif");
    opendir my $d, $sortie or die $!;
    my @livres = grep { /\Aapports_/ } readdir $d;
    is_deeply(\@livres, [], "$cas : rien n'est livré à l'outil de suivi");
    like(lire($r->{rejets_csv}), qr/;LOT;lot refusé : /, "$cas : le refus figure dans les rejets");
    ok(!-e "$sortie/.journal", "$cas : absent du journal, il sera retraité");
}

# --- Ce que les transferts font subir aux fichiers --------------------------------------

my $crlf = lot(apports => [ { bon => 1 }, { bon => 2 } ], fin_ligne => "\r\n") . "\x1A";
my ($r_lf, $s_lf) = passer(lot(apports => [ { bon => 1 }, { bon => 2 } ]));
my ($r_crlf, $s_crlf) = passer($crlf);
is($r_crlf->{statut}, 0, 'fins de ligne Windows et Ctrl-Z final : acceptés');
is(lire("$s_crlf/apports_MONT_000412.csv"), lire("$s_lf/apports_MONT_000412.csv"), 'même résultat qu\'avec des fins Unix');

(my $sans_blancs = $propre) =~ s/ +\n/\n/g;
isnt($sans_blancs, $propre, 'les blancs de fin de ligne ont bien été retirés');
($r) = passer($sans_blancs);
is($r->{statut}, 0, 'blancs de fin de ligne supprimés en route : tolérés');

($r, $sortie) = passer(assembler([ entete(), $un, "${un}XX", 'Z' . (' ' x 81), '', fin(2, 2 * $m) ]));
is($r->{statut}, 1, 'lignes abîmées : rejetées, le lot passe');
is_deeply([ @$r{qw(apports_lus acceptes rejetes)} ], [ 2, 1, 3 ], 'ligne trop longue, type inconnu, ligne vide');
$rejets = lire("$sortie/rejets_MONT_000412.csv");
like($rejets, qr/;ligne de 84 caractères au lieu de 82;/, 'ligne trop longue');
like($rejets, qr/;type d'enregistrement « Z » inconnu;/, 'type inconnu');
like($rejets, qr/;ligne vide;/, 'ligne vide');

my $illisible = apport(bon => 2);
substr($illisible, 73, 9, '0001A345B');
($r, $sortie) = passer(assembler([ entete(), $un, $illisible, fin(2, 0) ]));
is($r->{statut}, 1, 'montant illisible : la ligne est rejetée, le lot passe');
like($r->{avertissement}, qr/total de contrôle non vérifié/, 'et on prévient que le total n\'a pas pu être vérifié');

($r, $sortie) = passer(lot(apports => [ { nom => 'MME HÉLÈNE FAURÉ', encodage => 'latin1' } ]), encodage => 'latin1');
like(lire("$sortie/apports_MONT_000412.csv"), qr/,MME HÉLÈNE FAURÉ,/, 'encodage latin1 au choix');

is_deeply([ restes($sortie) ], [], 'aucun fichier temporaire ne traîne');

# --- Erreurs d'utilisation -------------------------------------------------------------------

like(eval { passer($propre, encodage => 'klingon'); 1 } ? '' : $@, qr/Encodage inconnu : klingon/, 'encodage inconnu');
like(eval { traiter_fichier(fichier => '/nulle/part', format => $format, produits => $produits); 1 } ? '' : $@,
    qr/Fichier introuvable/, 'fichier introuvable');

done_testing;
