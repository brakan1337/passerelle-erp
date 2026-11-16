package Passerelle::Lot;

# Traite un fichier d'export : un en-tête, les apports, une fin de lot.
# Les apports valides vont dans un CSV pour l'outil de suivi ; les autres
# dans un fichier de rejets, avec le champ en cause et la raison.
#
# Un lot entier est refusé, sans rien livrer à l'outil de suivi, quand le
# fichier lui-même n'est pas fiable : en-tête ou fin de lot absents ou
# illisibles, nombre d'apports ou total qui ne correspondent pas à la fin de
# lot (fichier tronqué pendant le transfert, lignes perdues).

use 5.010_001;
use strict;
use warnings;
use utf8;

use Carp qw(croak);
use Digest::SHA ();
use Encode ();
use File::Basename qw(basename);
use File::Spec;
use POSIX qw(strftime);

use Passerelle::Controles qw(controler_apport date_valide en_iso);
use Passerelle::Csv qw(ligne_csv);
use Passerelle::Decodage qw(decoder_enregistrement en_decimal en_francais);

use Exporter 'import';

our @EXPORT_OK = qw(traiter_fichier charger_produits verifier_format);

my %CHAMPS_REQUIS = (
    ENTETE    => [qw(CODE-SITE DATE-EXPORT NUM-LOT)],
    APPORT    => [qw(NUM-BON NUM-ADHERENT NOM-ADHERENT DATE-APPORT CODE-PRODUIT POIDS-KG HUMIDITE PRIX-TONNE MONTANT)],
    'FIN-LOT' => [qw(NB-APPORTS TOTAL-MONTANT)],
);
my %ROLE = (ENTETE => 'entete', APPORT => 'apport', 'FIN-LOT' => 'fin');

my @COLONNES_APPORTS = qw(
  site lot num_bon num_adherent nom_adherent date_apport code_produit produit
  poids_kg humidite_pct prix_tonne_eur montant_eur
);
my @COLONNES_REJETS = qw(fichier ligne num_bon champ motif contenu);

sub verifier_format {
    my ($format) = @_;
    for my $nom (sort keys %CHAMPS_REQUIS) {
        my $enregistrement = $format->{par_nom}{$nom}
          or croak "Le format ne décrit pas l'enregistrement $nom";
        my @manquants = grep { !$enregistrement->{par_nom}{$_} } @{ $CHAMPS_REQUIS{$nom} };
        croak "L'enregistrement $nom du format n'a pas les champs : @manquants" if @manquants;
    }
    my $montant = $format->{par_nom}{APPORT}{par_nom}{MONTANT};
    my $total   = $format->{par_nom}{'FIN-LOT'}{par_nom}{'TOTAL-MONTANT'};
    croak 'MONTANT et TOTAL-MONTANT doivent avoir le même nombre de décimales'
      if $montant->{decimales} != $total->{decimales};
    return 1;
}

# Référentiel des produits, un CSV « code;libelle » en UTF-8.
sub charger_produits {
    my ($chemin) = @_;
    open my $fh, '<:encoding(UTF-8)', $chemin
      or croak "Impossible de lire le référentiel $chemin : $!";
    my %produits;
    my $n = 0;
    while (my $ligne = <$fh>) {
        $n++;
        $ligne =~ s/\r?\n\z//;
        next if $n == 1 || $ligne !~ /\S/;    # la première ligne nomme les colonnes
        my ($code, $libelle) = split /;/, $ligne, 2;
        croak "$chemin, ligne $n : « code;libelle » attendu"
          if !defined $libelle || $code !~ /\S/;
        $produits{$code} = $libelle;
    }
    close $fh;
    croak "Le référentiel $chemin est vide" if !%produits;
    return \%produits;
}

# Options : fichier, format, produits, sortie (dossier), encodage, force.
sub traiter_fichier {
    my (%o) = @_;
    my $fichier  = $o{fichier}  // croak 'traiter_fichier : fichier manquant';
    my $format   = $o{format}   // croak 'traiter_fichier : format manquant';
    my $produits = $o{produits} // croak 'traiter_fichier : référentiel des produits manquant';
    my $sortie   = $o{sortie}   // '.';
    my $nom_encodage = $o{encodage} // 'cp850';
    my $encodage = Encode::find_encoding($nom_encodage)
      or croak "Encodage inconnu : $nom_encodage";
    verifier_format($format);
    croak "Fichier introuvable : $fichier"            if !-f $fichier;
    croak "Dossier de sortie introuvable : $sortie"   if !-d $sortie;

    my $nom       = basename($fichier);
    my $empreinte = Digest::SHA->new(256)->addfile($fichier, 'b')->hexdigest;
    my $journal   = File::Spec->catfile($sortie, '.journal');

    # Un fichier déjà livré n'est pas relivré : le cron peut repasser sans risque.
    if (!$o{force}) {
        my $deja = _deja_traite($journal, $empreinte);
        return { fichier => $nom, statut => 0, deja => $deja } if $deja;
    }

    # On écrit dans des fichiers temporaires, renommés seulement à la fin :
    # l'outil de suivi ne voit jamais un fichier à moitié écrit.
    my %parts = map { $_ => File::Spec->catfile($sortie, ".$nom.$$.$_.part") } qw(apports rejets);
    my $bilan = eval { _lire_lot($fichier, $nom, $format, $produits, $encodage, \%parts) };
    if (!$bilan) {
        my $erreur = $@;
        unlink values %parts;
        die $erreur;
    }

    my $base = $bilan->{entete} ? "$bilan->{entete}{site}_$bilan->{entete}{lot}" : $nom;
    $base =~ s/\.[^.]*\z// if !$bilan->{entete};
    $base =~ s/[^A-Za-z0-9_-]+/_/g;
    my $vers_apports = File::Spec->catfile($sortie, "apports_$base.csv");
    my $vers_rejets  = File::Spec->catfile($sortie, "rejets_$base.csv");

    my %resultat = (
        fichier       => $nom,
        deja          => undef,
        site          => $bilan->{entete} ? $bilan->{entete}{site} : undef,
        lot           => $bilan->{entete} ? $bilan->{entete}{lot}  : undef,
        apports_lus   => $bilan->{apports_lus},
        acceptes      => $bilan->{acceptes},
        rejetes       => $bilan->{rejetes},
        avertissement => $bilan->{avertissement},
        refus         => $bilan->{refus} ? $bilan->{refus}[1] : undef,
    );

    if ($bilan->{refus}) {
        unlink $parts{apports};
        _renommer($parts{rejets}, $vers_rejets);
        $resultat{rejets_csv} = $vers_rejets;
        $resultat{statut}     = 2;
        return \%resultat;
    }

    _renommer($parts{apports}, $vers_apports);
    $resultat{apports_csv} = $vers_apports;
    if ($bilan->{lignes_rejet}) {
        _renommer($parts{rejets}, $vers_rejets);
        $resultat{rejets_csv} = $vers_rejets;
    }
    else {
        # Un lot réexporté après correction ne garde pas les rejets de la veille.
        unlink $parts{rejets}, (-e $vers_rejets ? $vers_rejets : ());
    }

    open my $j, '>>:utf8', $journal or croak "Impossible d'écrire le journal $journal : $!";
    print {$j} join("\t", $empreinte, strftime('%Y-%m-%d %H:%M', localtime), $nom, $base,
        $resultat{acceptes}, $resultat{rejetes}), "\n";
    close $j or croak "Impossible d'écrire le journal $journal : $!";

    $resultat{statut} = ($resultat{rejetes} || $resultat{avertissement}) ? 1 : 0;
    return \%resultat;
}

sub _lire_lot {
    my ($fichier, $nom, $format, $produits, $encodage, $parts) = @_;

    open my $entree, '<:raw', $fichier or croak "Impossible de lire $fichier : $!";
    open my $apports, '>:utf8', $parts->{apports} or croak "Impossible d'écrire $parts->{apports} : $!";
    open my $rejets,  '>:utf8', $parts->{rejets}  or croak "Impossible d'écrire $parts->{rejets} : $!";

    # Les apports partent vers une machine : CSV standard, virgule, point décimal.
    # Les rejets sont lus par une personne dans Excel : point-virgule et BOM,
    # pour que les accents et les colonnes s'affichent bien.
    print {$apports} ligne_csv(',', @COLONNES_APPORTS);
    print {$rejets} "\x{FEFF}", ligne_csv(';', @COLONNES_REJETS);

    my $enregistrements = $format->{enregistrements};
    my $longueur_code   = $format->{longueur_code};
    my %decimales = map { $_->{nom} => $_->{decimales} }
      grep { $_->{type} eq '9' } @{ $format->{par_nom}{APPORT}{champs} };

    my %bilan = (apports_lus => 0, acceptes => 0, rejetes => 0, lignes_rejet => 0);
    my %ctx   = (produits => $produits, bons => {}, decimales => \%decimales);
    my ($entete, $fin);
    my ($total, $total_lisible) = (0, 1);
    my $phase = 'debut';
    my $n     = 0;

    my $rejeter = sub {
        my ($ligne, $bon, $champ, $motif, $contenu) = @_;
        if (defined $contenu) {
            $contenu = $encodage->decode("$contenu");
            $contenu =~ tr/\x00-\x1F/ /;
        }
        print {$rejets} ligne_csv(';', $nom, $ligne, $bon, $champ, $motif, $contenu);
        $bilan{lignes_rejet}++;
    };

  LIGNE:
    while (my $ligne = <$entree>) {
        $n++;
        $ligne =~ s/\r?\n\z//;
        $ligne =~ s/\x1A+\z//;    # marque de fin de fichier des outils DOS (Ctrl-Z)

        if ($phase eq 'fin') {
            next LIGNE if $ligne !~ /\S/;
            $bilan{refus} = [ $n, 'données après la fin de lot' ];
            last LIGNE;
        }
        if ($ligne !~ /\S/) {
            $rejeter->($n, '', '', 'ligne vide', '');
            $bilan{rejetes}++;
            next LIGNE;
        }

        my $code           = substr $ligne, 0, $longueur_code;
        my $enregistrement = $enregistrements->{$code};
        if (!$enregistrement) {
            $rejeter->($n, '', '', "type d'enregistrement « " . $encodage->decode("$code") . ' » inconnu', $ligne);
            $bilan{rejetes}++;
            next LIGNE;
        }
        my $role = $ROLE{ $enregistrement->{nom} };
        next LIGNE if !$role;    # enregistrement décrit par le format, sans usage ici

        if ($role eq 'entete' && $phase ne 'debut') {
            $bilan{refus} = [ $n, 'second en-tête de lot' ];
            last LIGNE;
        }
        if ($role ne 'entete' && $phase eq 'debut') {
            $bilan{refus} = [ $n, ($role eq 'apport' ? 'apport' : 'fin de lot') . " avant l'en-tête de lot" ];
            last LIGNE;
        }

        my ($valeurs, $bruts, @erreurs) = ({}, {});
        if (length $ligne > $enregistrement->{longueur}) {
            push @erreurs, [ '', sprintf 'ligne de %d caractères au lieu de %d',
                length $ligne, $enregistrement->{longueur} ];
        }
        else {
            # Les transferts suppriment souvent les blancs de fin de ligne : on les remet.
            my $complete = $ligne . (' ' x ($enregistrement->{longueur} - length $ligne));
            my $decodage;
            ($valeurs, $bruts, $decodage) = decoder_enregistrement($enregistrement, $complete, $encodage);
            push @erreurs, @$decodage;
        }

        if ($role eq 'entete') {
            if (!@erreurs && !date_valide(sprintf '%08d', $valeurs->{'DATE-EXPORT'})) {
                push @erreurs, [ 'DATE-EXPORT', sprintf 'date %08d impossible', $valeurs->{'DATE-EXPORT'} ];
            }
            if (@erreurs) {
                $bilan{refus} = [ $n, 'en-tête illisible : ' . _motifs(@erreurs) ];
                last LIGNE;
            }
            $entete = {
                site => $valeurs->{'CODE-SITE'},
                lot  => $bruts->{'NUM-LOT'},
                date => sprintf('%08d', $valeurs->{'DATE-EXPORT'}),
            };
            $ctx{date_export} = $entete->{date};
            $phase = 'lot';
            next LIGNE;
        }

        if ($role eq 'fin') {
            if (@erreurs) {
                $bilan{refus} = [ $n, 'fin de lot illisible : ' . _motifs(@erreurs) ];
                last LIGNE;
            }
            $fin = { nb => $valeurs->{'NB-APPORTS'}, total => $valeurs->{'TOTAL-MONTANT'} };
            $phase = 'fin';
            next LIGNE;
        }

        # Un apport.
        $bilan{apports_lus}++;
        if (defined $valeurs->{MONTANT}) { $total += $valeurs->{MONTANT} }
        else                             { $total_lisible = 0 }
        $ctx{ligne} = $n;
        push @erreurs, controler_apport($valeurs, $bruts, \%ctx) if %$valeurs;

        if (@erreurs) {
            my $bon = defined $valeurs->{'NUM-BON'} ? $bruts->{'NUM-BON'} : '';
            $rejeter->($n, $bon, $_->[0], $_->[1], $ligne) for @erreurs;
            $bilan{rejetes}++;
            next LIGNE;
        }

        my $produit = $valeurs->{'CODE-PRODUIT'};
        print {$apports} ligne_csv(',',
            $entete->{site},
            $entete->{lot},
            $bruts->{'NUM-BON'},
            $bruts->{'NUM-ADHERENT'},
            $valeurs->{'NOM-ADHERENT'},
            en_iso(sprintf '%08d', $valeurs->{'DATE-APPORT'}),
            $produit,
            $produits->{$produit},
            en_decimal($valeurs->{'POIDS-KG'},   $decimales{'POIDS-KG'}),
            en_decimal($valeurs->{HUMIDITE},     $decimales{HUMIDITE}),
            en_decimal($valeurs->{'PRIX-TONNE'}, $decimales{'PRIX-TONNE'}),
            en_decimal($valeurs->{MONTANT},      $decimales{MONTANT}),
        );
        $bilan{acceptes}++;
    }
    close $entree;

    if (!$bilan{refus}) {
        my $d = $decimales{MONTANT};
        if ($phase eq 'debut') {
            $bilan{refus} = [ '', 'aucun en-tête de lot' ];
        }
        elsif ($phase eq 'lot') {
            $bilan{refus} = [ '', "fichier tronqué : l'enregistrement de fin de lot manque" ];
        }
        elsif ($fin->{nb} != $bilan{apports_lus}) {
            $bilan{refus} = [ '', sprintf 'la fin de lot annonce %d apports, le fichier en contient %d',
                $fin->{nb}, $bilan{apports_lus} ];
        }
        elsif (!$total_lisible) {
            $bilan{avertissement} = 'total de contrôle non vérifié : au moins un montant est illisible';
        }
        elsif ($fin->{total} != $total) {
            $bilan{refus} = [ '', sprintf 'la fin de lot annonce un total de %s €, les apports font %s €',
                en_francais($fin->{total}, $d), en_francais($total, $d) ];
        }
    }
    $rejeter->($bilan{refus}[0], '', 'LOT', "lot refusé : $bilan{refus}[1]", undef) if $bilan{refus};

    close $apports or croak "Impossible d'écrire $parts->{apports} : $!";
    close $rejets  or croak "Impossible d'écrire $parts->{rejets} : $!";

    $bilan{entete} = $entete;
    return \%bilan;
}

sub _motifs {
    return join ' ; ', map { $_->[0] ? "$_->[0] : $_->[1]" : $_->[1] } @_;
}

sub _renommer {
    my ($de, $vers) = @_;
    rename $de, $vers or croak "Impossible de renommer $de en $vers : $!";
    return;
}

sub _deja_traite {
    my ($journal, $empreinte) = @_;
    return if !-e $journal;
    open my $fh, '<:utf8', $journal or croak "Impossible de lire le journal $journal : $!";
    while (my $ligne = <$fh>) {
        chomp $ligne;
        my ($sha, $quand, $nom, $lot) = split /\t/, $ligne;
        next if !defined $sha || $sha ne $empreinte;
        close $fh;
        return { quand => $quand, nom => $nom, lot => $lot };
    }
    close $fh;
    return;
}

1;
