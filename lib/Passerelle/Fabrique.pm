package Passerelle::Fabrique;

# Fabrique des enregistrements au format formats/apports.cpy, octet pour
# octet comme l'ERP les écrit (CP850, signe dans le dernier chiffre).
# Sert aux tests, au générateur de fichiers d'essai et au banc de vitesse.

use 5.010_001;
use strict;
use warnings;
use utf8;

use Encode ();
use Exporter 'import';
use Time::Local qw(timegm);

use Passerelle::Controles qw(cle_luhn montant_attendu);

our @EXPORT_OK = qw(
  entete apport fin lot assembler montant_de texte surfrappe signe_separe ecrire_lot_aleatoire
);

sub texte {
    my ($valeur, $longueur, $encodage) = @_;
    my $octets = Encode::encode($encodage // 'cp850', $valeur);
    return substr($octets . (' ' x $longueur), 0, $longueur);
}

# Nombre signé, signe porté par le dernier chiffre : -12,34 sur 9 -> 00000123M
sub surfrappe {
    my ($valeur, $longueur) = @_;
    my $chiffres = sprintf '%0*.0f', $longueur, abs $valeur;
    my $dernier  = substr $chiffres, -1;
    my @zone     = $valeur < 0 ? ('}', 'J' .. 'R') : ('{', 'A' .. 'I');
    substr($chiffres, -1, 1, $zone[$dernier]);
    return $chiffres;
}

# Nombre signé, signe séparé à droite : -12,34 sur 11 chiffres -> 00000001234-
sub signe_separe {
    my ($valeur, $longueur) = @_;
    return sprintf('%0*.0f', $longueur, abs $valeur) . ($valeur < 0 ? '-' : '+');
}

sub entete {
    my (%o) = @_;
    return 'E'
      . texte($o{site} // 'MONT', 4)
      . ($o{date} // '20261116')
      . sprintf('%06d', $o{lot} // 412)
      . (' ' x 63);
}

# Poids en kg, humidité en dixièmes de %, prix et montant en centimes.
sub montant_de {
    my (%o) = @_;
    return $o{montant} if defined $o{montant};
    my $montant = montant_attendu($o{poids} // 24_500, 0, $o{prix} // 18_250, 2, 2);
    return $o{avoir} ? -$montant : $montant;
}

sub apport {
    my (%o) = @_;
    return 'L'
      . sprintf('%08d', $o{bon} // 10_000_001)
      . ($o{adherent} // cle_luhn('100001'))
      . texte($o{nom} // 'GAEC DES PRÉS', 30, $o{encodage})
      . ($o{date} // '20261115')
      . texte($o{produit} // 'BLTE', 4)
      . sprintf('%06d', $o{poids} // 24_500)
      . sprintf('%03d', $o{humidite} // 145)
      . sprintf('%06d', $o{prix} // 18_250)
      . surfrappe(montant_de(%o), 9);
}

sub fin {
    my ($nb, $total) = @_;
    # Comme l'ERP, on refuse d'écrire un total que le champ ne peut pas contenir.
    die "Total de $total centimes : trop grand pour TOTAL-MONTANT, S9(9)V99\n"
      if abs($total) > 99_999_999_999;
    die "$nb apports : trop pour NB-APPORTS, 9(6)\n" if $nb > 999_999;
    return 'T' . sprintf('%06d', $nb) . signe_separe($total, 11) . (' ' x 63);
}

sub assembler {
    my ($lignes, $fin_ligne) = @_;
    $fin_ligne //= "\n";
    return join '', map { "$_$fin_ligne" } @$lignes;
}

# Un lot complet et cohérent ; « fin » permet de fausser la fin de lot.
sub lot {
    my (%o) = @_;
    my @apports = @{ $o{apports} // [ {} ] };
    my @lignes  = (entete(%{ $o{entete} // {} }), map { apport(%$_) } @apports);
    my $total   = 0;
    $total += montant_de(%$_) for @apports;
    my %fin = (nb => scalar @apports, total => $total, %{ $o{fin} // {} });
    push @lignes, fin($fin{nb}, $fin{total});
    return assembler(\@lignes, $o{fin_ligne});
}

my @FORMES = ('GAEC', 'EARL', 'SCEA', 'M.', 'MME');
my @NOMS   = (
    'DES PRÉS',  'DU MOULIN', 'LES CHÊNES', 'FAURÉ',     'PÉRÈS',      'DE LA NOË',
    'BELLEVUE',  'LEFÈVRE',   'GARÇON',     'DU CRÊT',   'MARTINEAU',  'ROUSSEL',
);

# Prix (centimes la tonne) et humidité (dixièmes de %) plausibles par produit.
my %PRODUITS = (
    BLTE => [ 17_000, 21_000, 110, 160 ],
    BLDU => [ 24_000, 30_000, 110, 150 ],
    ORGE => [ 16_000, 19_500, 110, 150 ],
    ORFO => [ 15_000, 17_500, 110, 150 ],
    MAIS => [ 16_500, 20_000, 150, 320 ],
    COLZ => [ 42_000, 48_000, 60,  100 ],
    TOUR => [ 38_000, 44_000, 60,  110 ],
    POIS => [ 22_000, 26_000, 120, 160 ],
    SOJA => [ 38_000, 42_000, 110, 150 ],
);
my @TIRAGE = (('BLTE') x 5, ('ORGE') x 2, ('MAIS') x 3, 'BLDU', 'ORFO', ('COLZ') x 2, 'TOUR', 'POIS', 'SOJA');

# Les fautes qu'on retrouve dans les vrais exports, une de chaque.
my @FAUTES = qw(cle produit date humidite montant doublon poids nom);

sub ecrire_lot_aleatoire {
    my ($fh, %o) = @_;
    my $n         = $o{apports} // 1000;
    my $date      = $o{date}    // '20261116';
    my $fin_ligne = $o{fin_ligne} // "\n";
    srand($o{graine} // 412);

    my %fautes;
    if ($o{erreurs}) {
        for my $k (0 .. $#FAUTES) {
            my $i = int(($k + 0.5) * $n / @FAUTES);
            $fautes{$i} = $FAUTES[$k] if $i < $n && !exists $fautes{$i};
        }
    }

    my @adherents = map { cle_luhn(sprintf '%06d', 100_001 + $_) } 0 .. 59;
    my $midi = timegm(0, 0, 12, substr($date, 6, 2), substr($date, 4, 2) - 1, substr($date, 0, 4));
    print {$fh} entete(site => $o{site} // 'MONT', date => $date, lot => $o{lot} // 412), $fin_ligne;

    my ($total, $bon_precedent) = (0, undef);
    for my $i (0 .. $n - 1) {
        my $produit = $TIRAGE[ int rand @TIRAGE ];
        my ($prix_min, $prix_max, $hum_min, $hum_max) = @{ $PRODUITS{$produit} };
        my $k = int rand 60;
        my @jour = gmtime($midi - int(rand 21) * 86_400);
        my %apport = (
            bon      => 10_000_001 + $i,
            adherent => $adherents[$k],
            nom      => "$FORMES[$k % @FORMES] $NOMS[int($k / @FORMES) % @NOMS]",
            date     => sprintf('%04d%02d%02d', $jour[5] + 1900, $jour[4] + 1, $jour[3]),
            produit  => $produit,
            poids    => 8_000 + int rand 23_000,
            humidite => $hum_min + int rand($hum_max - $hum_min + 1),
            prix     => 5 * int(($prix_min + rand($prix_max - $prix_min)) / 5),
            avoir    => (rand() < 0.01 ? 1 : 0),
        );

        my $faute = $fautes{$i} // '';
        if    ($faute eq 'cle')      { substr($apport{adherent}, -1, 1, (substr($apport{adherent}, -1) + 1) % 10) }
        elsif ($faute eq 'produit')  { $apport{produit}  = 'BLE' }
        elsif ($faute eq 'date')     { $apport{date}     = substr($date, 0, 4) . '0230' }
        elsif ($faute eq 'humidite') { $apport{humidite} = 412 }
        elsif ($faute eq 'montant')  { $apport{montant}  = montant_de(%apport) + 10_000 }
        elsif ($faute eq 'doublon')  { $apport{bon}      = $bon_precedent }
        elsif ($faute eq 'nom')      { $apport{nom}      = '' }

        my $ligne = apport(%apport);
        substr($ligne, 58, 6, '012O40') if $faute eq 'poids';    # la lettre O au lieu d'un zéro
        $total += montant_de(%apport);
        $bon_precedent = $apport{bon};
        print {$fh} $ligne, $fin_ligne;
    }
    print {$fh} fin($n, $total), $fin_ligne;
    return { apports => $n, total => $total, fautes => scalar keys %fautes };
}

1;
