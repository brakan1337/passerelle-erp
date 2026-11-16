package Passerelle::Controles;

# Les règles métier d'un apport : ce que l'ERP laisse passer, et que l'outil
# de suivi ne doit pas recevoir.

use 5.010_001;
use strict;
use warnings;
use utf8;

use Exporter 'import';
use Passerelle::Decodage qw(en_francais);

our @EXPORT_OK = qw(
  controler_apport cle_luhn cle_luhn_valide date_valide en_iso date_fr montant_attendu
);

# Au-delà, le grain n'est pas réceptionnable : c'est une erreur de saisie.
my $HUMIDITE_MAX = 35;

# $valeurs : champs décodés (absents s'ils étaient illisibles).
# $bruts   : texte d'origine des champs (les numéros gardent leurs zéros).
# $ctx     : produits, date_export, decimales, bons déjà vus, ligne courante.
# Renvoie la liste des erreurs, chacune [champ, motif].
sub controler_apport {
    my ($valeurs, $bruts, $ctx) = @_;
    my $dec = $ctx->{decimales};
    my @erreurs;

    if (defined $valeurs->{'NUM-ADHERENT'} && !cle_luhn_valide($bruts->{'NUM-ADHERENT'})) {
        push @erreurs, [ 'NUM-ADHERENT', "clé de contrôle fausse pour l'adhérent $bruts->{'NUM-ADHERENT'}" ];
    }

    if (defined $valeurs->{'NOM-ADHERENT'} && $valeurs->{'NOM-ADHERENT'} !~ /\S/) {
        push @erreurs, [ 'NOM-ADHERENT', "nom d'adhérent vide" ];
    }

    if (defined $valeurs->{'DATE-APPORT'}) {
        my $date = sprintf '%08d', $valeurs->{'DATE-APPORT'};
        if (!date_valide($date)) {
            push @erreurs, [ 'DATE-APPORT', "date $date impossible" ];
        }
        elsif (defined $ctx->{date_export} && $date gt $ctx->{date_export}) {
            push @erreurs, [ 'DATE-APPORT',
                'apport daté du ' . date_fr($date) . ", après l'export du " . date_fr($ctx->{date_export}) ];
        }
    }

    my $produit = $valeurs->{'CODE-PRODUIT'};
    if (defined $produit && !exists $ctx->{produits}{$produit}) {
        push @erreurs, [ 'CODE-PRODUIT', "produit « $produit » absent du référentiel" ];
    }

    my $poids_lisible = defined $valeurs->{'POIDS-KG'};
    if ($poids_lisible && $valeurs->{'POIDS-KG'} <= 0) {
        push @erreurs, [ 'POIDS-KG', 'poids nul' ];
        $poids_lisible = 0;
    }

    my $humidite = $valeurs->{HUMIDITE};
    if (defined $humidite && $humidite > $HUMIDITE_MAX * 10**$dec->{HUMIDITE}) {
        push @erreurs, [ 'HUMIDITE',
            'humidité de ' . en_francais($humidite, $dec->{HUMIDITE}) . " %, au-delà de $HUMIDITE_MAX %" ];
    }

    # Le montant doit valoir poids x prix à la tonne, au centime près.
    # Un avoir porte un montant négatif, de même valeur absolue.
    my $montant = $valeurs->{MONTANT};
    if ($poids_lisible && defined $valeurs->{'PRIX-TONNE'} && defined $montant) {
        my $attendu = montant_attendu(
            $valeurs->{'POIDS-KG'},   $dec->{'POIDS-KG'},
            $valeurs->{'PRIX-TONNE'}, $dec->{'PRIX-TONNE'},
            $dec->{MONTANT},
        );
        if (abs(abs($montant) - $attendu) > 1) {
            push @erreurs, [ 'MONTANT', sprintf 'montant de %s € au lieu de %s € (%s kg à %s €/t)',
                en_francais($montant, $dec->{MONTANT}),
                en_francais($montant < 0 ? -$attendu : $attendu, $dec->{MONTANT}),
                en_francais($valeurs->{'POIDS-KG'}, $dec->{'POIDS-KG'}),
                en_francais($valeurs->{'PRIX-TONNE'}, $dec->{'PRIX-TONNE'}) ];
        }
    }

    if (defined $valeurs->{'NUM-BON'}) {
        my $bon = $bruts->{'NUM-BON'};
        if (my $avant = $ctx->{bons}{$bon}) {
            push @erreurs, [ 'NUM-BON', "bon $bon déjà présent ligne $avant" ];
        }
        else {
            $ctx->{bons}{$bon} = $ctx->{ligne};
        }
    }

    return @erreurs;
}

# Montant = poids (kg) / 1000 x prix à la tonne, arrondi au plus proche.
# Chaque valeur est un entier à l'échelle de son champ.
sub montant_attendu {
    my ($poids, $dec_poids, $prix, $dec_prix, $dec_montant) = @_;
    my $numerateur   = $poids * $prix * 10**$dec_montant;
    my $denominateur = 1000 * 10**($dec_poids + $dec_prix);
    return int(($numerateur + $denominateur / 2) / $denominateur);
}

# Clé de Luhn : le dernier chiffre du numéro d'adhérent contrôle les autres,
# et détecte toute faute de frappe sur un chiffre.
sub cle_luhn_valide {
    my ($numero) = @_;
    return 0 if !defined $numero || $numero !~ /\A[0-9]{2,}\z/;
    my ($somme, $double) = (0, 0);
    for my $chiffre (reverse split //, $numero) {
        if ($double) {
            $chiffre *= 2;
            $chiffre -= 9 if $chiffre > 9;
        }
        $somme += $chiffre;
        $double = !$double;
    }
    return $somme % 10 == 0;
}

sub cle_luhn {
    my ($base) = @_;
    for my $cle (0 .. 9) {
        return "$base$cle" if cle_luhn_valide("$base$cle");
    }
    return;
}

sub date_valide {
    my ($date) = @_;
    return 0 if !defined $date || $date !~ /\A([0-9]{4})([0-9]{2})([0-9]{2})\z/;
    my ($annee, $mois, $jour) = ($1, $2, $3);
    return 0 if $annee < 1900 || $mois < 1 || $mois > 12 || $jour < 1;
    my $bissextile = ($annee % 4 == 0 && $annee % 100 != 0) || $annee % 400 == 0;
    my @jours = (31, $bissextile ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return $jour <= $jours[ $mois - 1 ] ? 1 : 0;
}

sub en_iso {
    my ($date) = @_;
    return join '-', substr($date, 0, 4), substr($date, 4, 2), substr($date, 6, 2);
}

sub date_fr {
    my ($date) = @_;
    return join '/', substr($date, 6, 2), substr($date, 4, 2), substr($date, 0, 4);
}

1;
