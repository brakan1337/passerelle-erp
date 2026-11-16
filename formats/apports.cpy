      *----------------------------------------------------------------
      * EXPORT NOCTURNE DES APPORTS - ERP GESTION COOPERATIVE (1997)
      * Fichier sequentiel, un enregistrement par ligne, 82 caracteres.
      * Encodage du serveur : CP850.
      *----------------------------------------------------------------
       01  ENTETE.
           05  TYPE-ENR             PIC X        VALUE 'E'.
           05  CODE-SITE            PIC X(4).
           05  DATE-EXPORT          PIC 9(8).
           05  NUM-LOT              PIC 9(6).
           05  FILLER               PIC X(63).
      *
       01  APPORT.
           05  TYPE-ENR             PIC X        VALUE 'L'.
           05  NUM-BON              PIC 9(8).
           05  ADHERENT.
               10  NUM-ADHERENT     PIC 9(7).
               10  NOM-ADHERENT     PIC X(30).
           05  DATE-APPORT          PIC 9(8).
           05  CODE-PRODUIT         PIC X(4).
           05  POIDS-KG             PIC 9(6).
           05  HUMIDITE             PIC 9(2)V9.
           05  PRIX-TONNE           PIC 9(4)V99.
           05  MONTANT              PIC S9(7)V99.
               88  AVOIR            VALUE -9999999.99 THRU -0.01.
      *
       01  FIN-LOT.
           05  TYPE-ENR             PIC X        VALUE 'T'.
           05  NB-APPORTS           PIC 9(6).
           05  TOTAL-MONTANT        PIC S9(9)V99
                                    SIGN IS TRAILING SEPARATE.
           05  FILLER               PIC X(63).
