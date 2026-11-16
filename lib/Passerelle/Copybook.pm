package Passerelle::Copybook;

# Lit la description des enregistrements telle que l'ERP la documente : un
# « copybook » COBOL. La mise en page du fichier d'export n'est donc pas
# recopiée à la main dans le code, elle vient de la source.
#
# Sous-ensemble pris en charge, celui des fichiers d'export texte :
#   PIC X(n), PIC 9(n), PIC S9(n)V9(m), en USAGE DISPLAY ;
#   signe inclus dans le dernier chiffre (par défaut) ou SIGN SEPARATE ;
#   groupes (aplatis), niveaux 88 (ignorés), FILLER.
# Le reste (COMP-3, OCCURS, REDEFINES...) est refusé avec un message clair,
# plutôt que de produire une mise en page fausse.

use 5.010_001;
use strict;
use warnings;
use utf8;

use Carp qw(croak);
use Exporter 'import';

our @EXPORT_OK = qw(lire_copybook analyser_copybook developper_pic);

# Au-delà de 15 chiffres, un nombre Perl ne garantit plus la précision.
my $CHIFFRES_MAX = 15;

sub lire_copybook {
    my ($chemin) = @_;
    open my $fh, '<:encoding(UTF-8)', $chemin
      or croak "Impossible de lire le format $chemin : $!";
    local $/;
    my $texte = <$fh>;
    close $fh;
    return analyser_copybook($texte, $chemin);
}

sub analyser_copybook {
    my ($texte, $source) = @_;
    $source //= 'format';

    my @ordre;
    my $courant;
    for my $instruction (_instructions($texte, $source)) {
        my ($phrase, $n) = @$instruction;
        my $ou = "$source, ligne $n";
        my ($niveau, $nom, $reste) =
          $phrase =~ /\A\s*(\d\d?)\s+([A-Za-z0-9][A-Za-z0-9-]*)(.*)\z/s
          or croak "$ou : instruction illisible : « " . _net($phrase) . ' »';
        $niveau += 0;
        $nom = uc $nom;

        next if $niveau == 88;    # nom de condition : sans effet sur la mise en page
        croak "$ou : niveau $niveau non pris en charge"
          if $niveau == 66 || $niveau == 77 || $niveau > 49;

        my $clauses = _clauses($reste, $ou);

        if ($niveau == 1) {
            croak "$ou : l'enregistrement $nom doit se décomposer en champs"
              if defined $clauses->{pic};
            $courant = { nom => $nom, champs => [], longueur => 0, par_nom => {} };
            push @ordre, $courant;
            next;
        }
        croak "$ou : le champ $nom est hors de tout enregistrement 01" if !$courant;

        if (!defined $clauses->{pic}) {
            croak "$ou : clause de signe sur le groupe $nom non prise en charge"
              if $clauses->{signe};
            next;    # un groupe n'occupe pas de place : ses champs suivent
        }

        my $champ = { nom => $nom, debut => $courant->{longueur}, %{ developper_pic($clauses->{pic}, $ou) } };
        if ($champ->{type} eq '9') {
            if ($clauses->{signe}) {
                croak "$ou : clause SIGN sur $nom, dont la PIC n'a pas de S"
                  if !$champ->{signe_pic};
                $champ->{signe}    = $clauses->{signe}{separe} ? 'separe' : 'inclus';
                $champ->{position} = $clauses->{signe}{position};
            }
            elsif ($champ->{signe_pic}) {
                # Par défaut, COBOL range le signe dans la zone du dernier chiffre.
                $champ->{signe}    = 'inclus';
                $champ->{position} = 'fin';
            }
            else {
                $champ->{signe} = 'aucun';
            }
            $champ->{longueur} =
              $champ->{entiers} + $champ->{decimales} + ($champ->{signe} eq 'separe' ? 1 : 0);
        }
        elsif ($clauses->{signe}) {
            croak "$ou : clause SIGN sur le champ texte $nom";
        }
        $champ->{valeur} = $clauses->{valeur} if defined $clauses->{valeur};

        if ($nom ne 'FILLER') {
            croak "$ou : le champ $nom est défini deux fois dans $courant->{nom}"
              if $courant->{par_nom}{$nom};
            $courant->{par_nom}{$nom} = $champ;
        }
        push @{ $courant->{champs} }, $champ;
        $courant->{longueur} += $champ->{longueur};
    }

    croak "$source : aucun enregistrement 01" if !@ordre;

    my (%enregistrements, $longueur_code);
    for my $e (@ordre) {
        croak "$source : l'enregistrement $e->{nom} n'a aucun champ" if !@{ $e->{champs} };
        my $premier = $e->{champs}[0];
        croak "$source : le premier champ de $e->{nom} doit porter le code de "
          . "l'enregistrement (PIC X... VALUE '...')"
          if $premier->{type} ne 'X'
          || !defined $premier->{valeur}
          || length($premier->{valeur}) != $premier->{longueur};
        $longueur_code //= $premier->{longueur};
        croak "$source : les codes d'enregistrement n'ont pas tous la même longueur"
          if $premier->{longueur} != $longueur_code;
        croak "$source : deux enregistrements portent le code « $premier->{valeur} »"
          if $enregistrements{ $premier->{valeur} };

        $e->{code}    = $premier->{valeur};
        $e->{gabarit} = join ' ', map { "a$_->{longueur}" } @{ $e->{champs} };
        $enregistrements{ $e->{code} } = $e;
    }

    return {
        enregistrements => \%enregistrements,
        ordre           => [ map { $_->{code} } @ordre ],
        par_nom         => { map { $_->{nom} => $_ } @ordre },
        longueur_code   => $longueur_code,
    };
}

# PIC X(4) -> texte de 4 ; PIC S9(7)V99 -> nombre signé, 7 entiers, 2 décimales.
sub developper_pic {
    my ($pic, $ou) = @_;
    $ou //= 'format';
    my $p = uc $pic;
    $p =~ s/([XA9])\((\d+)\)/$1 x $2/ge;

    return { type => 'X', longueur => length $p } if $p =~ /\A[XA]+\z/;

    if ($p =~ /\A(S?)(9+)(?:V(9*))?\z/) {
        my ($entiers, $decimales) = (length $2, length($3 // ''));
        croak "$ou : PIC $pic : plus de $CHIFFRES_MAX chiffres"
          if $entiers + $decimales > $CHIFFRES_MAX;
        return {
            type      => '9',
            signe_pic => ($1 ? 1 : 0),
            entiers   => $entiers,
            decimales => $decimales,
            longueur  => $entiers + $decimales,
        };
    }
    croak "$ou : PIC $pic non prise en charge (seules X(n), 9(n) et S9(n)V9(m) le sont)";
}

# Découpe le texte en instructions, chacune terminée par un point.
sub _instructions {
    my ($texte, $source) = @_;
    my @instructions;
    my $courante = '';
    my $n        = 0;
    for my $ligne (split /\r?\n/, $texte) {
        $n++;
        # Colonnes 1 à 6 : numéro de séquence. Colonne 7 : indicateur.
        # Colonnes 8 à 72 : le code. Au-delà : zone d'identification, ignorée.
        next if length($ligne) < 8;
        my $indicateur = substr $ligne, 6, 1;
        next if $indicateur eq '*' || $indicateur eq '/';
        croak "$source, ligne $n : suite de littéral (« - » en colonne 7) non prise en charge"
          if $indicateur eq '-';
        my $code = substr $ligne, 7, 65;
        next if $code !~ /\S/;
        $courante .= " $code";
        while ($courante =~ s/\A\s*((?:'[^']*'|"[^"]*"|[^'".]|\.(?=\S))*)\.(?=\s|\z)//) {
            push @instructions, [ $1, $n ];
        }
    }
    croak "$source : instruction non terminée par un point : « " . _net($courante) . ' »'
      if $courante =~ /\S/;
    return @instructions;
}

sub _clauses {
    my ($texte, $ou) = @_;
    my @jetons = $texte =~ /('[^']*'|"[^"]*"|\S+)/g;
    my %clauses;
    my $is = sub { shift @jetons if @jetons && uc $jetons[0] eq 'IS' };

    while (@jetons) {
        my $mot = uc shift @jetons;
        if ($mot eq 'PIC' || $mot eq 'PICTURE') {
            $is->();
            croak "$ou : PIC sans description" if !@jetons;
            $clauses{pic} = shift @jetons;
        }
        elsif ($mot eq 'VALUE' || $mot eq 'VALUES') {
            $is->();
            croak "$ou : VALUE sans valeur" if !@jetons;
            my $valeur = shift @jetons;
            $valeur =~ s/\A(['"])(.*)\1\z/$2/s;
            $clauses{valeur} = $valeur;
        }
        elsif ($mot eq 'SIGN' || $mot eq 'LEADING' || $mot eq 'TRAILING') {
            if ($mot eq 'SIGN') {
                $is->();
                $mot = uc(shift(@jetons) // '');
            }
            croak "$ou : SIGN doit être suivi de LEADING ou TRAILING"
              if $mot ne 'LEADING' && $mot ne 'TRAILING';
            my $separe = 0;
            if (@jetons && uc $jetons[0] eq 'SEPARATE') {
                shift @jetons;
                $separe = 1;
                shift @jetons if @jetons && uc $jetons[0] eq 'CHARACTER';
            }
            $clauses{signe} = { position => ($mot eq 'LEADING' ? 'debut' : 'fin'), separe => $separe };
        }
        elsif ($mot eq 'USAGE' || $mot eq 'DISPLAY') {
            next if $mot eq 'DISPLAY';
            $is->();
            my $usage = uc(shift(@jetons) // '');
            _binaire($usage, $ou) if $usage ne 'DISPLAY';
        }
        elsif ($mot =~ /\A(?:COMP(?:UTATIONAL)?(?:-\d)?|BINARY|PACKED-DECIMAL|POINTER|INDEX)\z/) {
            _binaire($mot, $ou);
        }
        elsif ($mot =~ /\A(?:OCCURS|REDEFINES|RENAMES|JUSTIFIED|JUST|BLANK|SYNCHRONIZED|SYNC)\z/) {
            croak "$ou : clause $mot non prise en charge";
        }
        else {
            croak "$ou : clause inconnue « $mot »";
        }
    }
    return \%clauses;
}

sub _binaire {
    my ($usage, $ou) = @_;
    croak "$ou : stockage « $usage » non pris en charge : "
      . "l'export doit être en DISPLAY, c'est-à-dire en texte lisible";
}

sub _net {
    my ($texte) = @_;
    $texte =~ s/\s+/ /g;
    $texte =~ s/\A\s|\s\z//g;
    return $texte;
}

1;
