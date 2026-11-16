package Passerelle::Decodage;

# Découpe une ligne du fichier d'export selon la mise en page du copybook,
# et décode chaque champ : texte dans l'encodage du serveur, nombres en
# entiers exacts (les centimes restent des entiers, jamais des flottants).

use 5.010_001;
use strict;
use warnings;
use utf8;

use Exporter 'import';

our @EXPORT_OK = qw(decoder_enregistrement decoder_nombre en_decimal en_francais);

# Signe « inclus » : COBOL le range dans la zone du dernier chiffre. Une fois
# l'export converti d'EBCDIC en ASCII, ce chiffre devient une lettre :
#   positif : { A B C D E F G H I   pour 0 à 9
#   négatif : } J K L M N O P Q R   pour 0 à 9
# Les compilateurs Micro Focus écrivent les négatifs p q r s t u v w x y.
# Un chiffre ordinaire vaut positif.
my %SURFRAPPE;
{
    my @positifs    = ('{', 'A' .. 'I');
    my @negatifs    = ('}', 'J' .. 'R');
    my @micro_focus = ('p' .. 'y');
    for my $i (0 .. 9) {
        $SURFRAPPE{ $positifs[$i] }    = [ $i, 0 ];
        $SURFRAPPE{ $negatifs[$i] }    = [ $i, 1 ];
        $SURFRAPPE{ $micro_focus[$i] } = [ $i, 1 ];
    }
}

# Renvoie (\%valeurs, \%bruts, \@erreurs). Les valeurs numériques sont des
# entiers à l'échelle du champ : 14,5 % en PIC 9(2)V9 vaut 145.
sub decoder_enregistrement {
    my ($enregistrement, $octets, $encodage) = @_;
    my @morceaux = unpack $enregistrement->{gabarit}, $octets;
    my (%valeurs, %bruts, @erreurs);
    my $champs = $enregistrement->{champs};

    for my $i (0 .. $#$champs) {
        my $champ = $champs->[$i];
        next if $champ->{nom} eq 'FILLER';
        my $morceau = $morceaux[$i];

        if ($champ->{type} eq 'X') {
            $morceau =~ tr/\x00/ /;    # LOW-VALUES : un champ jamais rempli
            # Les encodages des vieux serveurs (CP850, Latin-1...) gardent
            # l'ASCII tel quel : on ne décode que les textes qui en sortent.
            my $texte = $morceau =~ /[^\x20-\x7E]/ ? $encodage->decode($morceau) : $morceau;
            $texte =~ s/\s+\z//;
            if ($texte =~ /([\x00-\x1F\x7F])/) {
                push @erreurs, [ $champ->{nom}, sprintf 'caractère de contrôle 0x%02X dans le texte', ord $1 ];
                next;
            }
            $valeurs{ $champ->{nom} } = $bruts{ $champ->{nom} } = $texte;
            next;
        }

        $bruts{ $champ->{nom} } = $morceau;
        # Cas le plus courant : que des chiffres, signe éventuel compris.
        if ($morceau =~ /\A[0-9]+\z/ && $champ->{signe} ne 'separe') {
            $valeurs{ $champ->{nom} } = 0 + $morceau;
            next;
        }
        my ($valeur, $erreur) = decoder_nombre($champ, $morceau);
        if (defined $erreur) {
            $erreur = '« ' . $encodage->decode($morceau) . " » n'est pas un nombre"
              if $erreur eq 'pas un nombre';
            push @erreurs, [ $champ->{nom}, $erreur ];
        }
        else {
            $valeurs{ $champ->{nom} } = $valeur;
        }
    }
    return (\%valeurs, \%bruts, \@erreurs);
}

# Renvoie (valeur, undef) ou (undef, motif).
sub decoder_nombre {
    my ($champ, $texte) = @_;
    return (undef, 'champ numérique vide') if $texte =~ /\A[ \x00]*\z/;

    my $chiffres = $texte;
    my $negatif  = 0;
    if ($champ->{signe} eq 'separe') {
        my $signe =
          $champ->{position} eq 'debut'
          ? substr($chiffres, 0, 1, '')
          : substr($chiffres, -1, 1, '');
        if ($signe eq '-') {
            $negatif = 1;
        }
        elsif ($signe ne '+') {
            return (undef, 'signe absent, + ou - attendu') if $signe eq ' ';
            my $vu = $signe =~ /\A[!-~]\z/ ? "« $signe »" : sprintf('0x%02X', ord $signe);
            return (undef, "signe $vu invalide, + ou - attendu");
        }
    }
    elsif ($champ->{signe} eq 'inclus') {
        my $i = $champ->{position} eq 'debut' ? 0 : length($chiffres) - 1;
        if (my $s = $SURFRAPPE{ substr $chiffres, $i, 1 }) {
            substr($chiffres, $i, 1) = $s->[0];
            $negatif = $s->[1];
        }
    }

    return (undef, 'pas un nombre') if $chiffres !~ /\A[0-9]+\z/;
    my $valeur = 0 + $chiffres;
    return ($negatif && $valeur ? -$valeur : $valeur, undef);
}

# 447125 avec 2 décimales -> "4471.25" ; calcul exact, sans flottant.
sub en_decimal {
    my ($valeur, $decimales) = @_;
    return sprintf('%.0f', $valeur) if !$decimales;
    my $signe   = $valeur < 0 ? '-' : '';
    my $absolue = sprintf '%0*.0f', $decimales + 1, abs $valeur;
    return $signe . substr($absolue, 0, -$decimales) . '.' . substr($absolue, -$decimales);
}

# La même chose pour un message lu par une personne : virgule décimale.
sub en_francais {
    my $texte = en_decimal(@_);
    $texte =~ tr/./,/;
    return $texte;
}

1;
