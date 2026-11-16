# Passerelle ERP

[![CI](https://github.com/brakan1337/passerelle-erp/actions/workflows/ci.yml/badge.svg)](https://github.com/brakan1337/passerelle-erp/actions/workflows/ci.yml)

Une passerelle entre un vieil ERP et un outil de suivi moderne. Chaque nuit, l'ERP dépose un fichier d'export à largeur fixe. La passerelle le lit et contrôle chaque ligne. Elle écrit les apports valides en CSV pour le nouvel outil. Les autres lignes vont dans un fichier de rejets, avec le champ en cause et la raison.

**Perl, de 5.10.1 à la dernière version · modules de base uniquement · copybook COBOL · CP850 · Test::More**

## Le brief

> Ce projet est un cas d'étude. Le client est fictif ; le brief sert à justifier les choix techniques.

Une coopérative agricole enregistre les apports de grain de ses adhérents dans un ERP des années 1990, installé sur un vieux serveur Unix. Chaque nuit, l'ERP exporte les apports du jour dans un fichier texte. La coopérative vient d'adopter un outil de suivi en ligne, qui importe du CSV.

Le serveur ne peut pas être modifié : aucun logiciel ne doit y être installé, et l'éditeur de l'ERP a disparu.

**Pourquoi Perl :**
- **Il est déjà sur le serveur.** Perl fait partie de l'installation de base des Unix de cette génération : AIX, Solaris, HP-UX et les anciens Red Hat. Python 3, Java ou Node seraient à installer.
- **C'est l'outil historique de ce travail.** Il sait lire du texte ligne à ligne, le découper avec `unpack` et le contrôler avec des expressions régulières.

**La contrainte est vérifiée, pas seulement promise.** La passerelle n'utilise que les modules livrés avec Perl 5.10.1, sorti en 2009 : c'est la version d'AIX 7.1 et de Red Hat 6. Un test contrôle chaque module utilisé. La CI fait tourner tous les tests sous Perl 5.10, 5.18, 5.26, 5.34 et la dernière version.

## Une ligne de l'export

```
L100000011000033SCEA DES PRÉS                 20261109SOJA02329513904105500095637F
```

| Champ | Texte | Ce que la passerelle en fait |
|---|---|---|
| Type | `L` | une ligne d'apport (`E` : en-tête, `T` : fin de lot) |
| Bon | `10000001` | numéro de bon, zéros de tête conservés |
| Adhérent | `1000033` | le dernier chiffre est une clé de Luhn, vérifiée |
| Nom | `SCEA DES PRÉS` | décodé de CP850, l'encodage du serveur, vers UTF-8 |
| Date | `20261109` | `2026-11-09`, après contrôle du calendrier |
| Produit | `SOJA` | cherché dans le référentiel des produits |
| Poids | `023295` | 23 295 kg |
| Humidité | `139` | 13,9 % : la virgule est implicite (`PIC 9(2)V9`) |
| Prix | `041055` | 410,55 € la tonne |
| Montant | `00095637F` | **+9 563,76 €** : le `F` est le chiffre 6, porteur du signe + |

Le montant doit valoir le poids multiplié par le prix, au centime près. Le `F` final n'est pas une faute de frappe : c'est la manière COBOL d'écrire un nombre signé, expliquée plus bas.

## Utilisation

```bash
bin/passerelle --sortie sortie exemples/APP00412.DAT
```

```
APP00412.DAT : lot 000412 du site MONT, 40 apports lus, 32 acceptés, 8 rejetés
  apports : sortie/apports_MONT_000412.csv
  rejets  : sortie/rejets_MONT_000412.csv
```

Le fichier d'exemple contient une faute de chaque sorte rencontrée dans les vrais exports. Elles ressortent toutes dans les rejets :

| ligne | bon | champ | motif |
|---:|---|---|---|
| 4 | 10000003 | NUM-ADHERENT | clé de contrôle fausse pour l'adhérent 1000018 |
| 9 | 10000008 | CODE-PRODUIT | produit « BLE » absent du référentiel |
| 14 | 10000013 | DATE-APPORT | date 20260230 impossible |
| 19 | 10000018 | HUMIDITE | humidité de 41,2 %, au-delà de 35 % |
| 24 | 10000023 | MONTANT | montant de 3456,08 € au lieu de 3356,08 € (19569 kg à 171,50 €/t) |
| 29 | 10000027 | NUM-BON | bon 10000027 déjà présent ligne 28 |
| 34 | 10000033 | POIDS-KG | « 012O40 » n'est pas un nombre |
| 39 | 10000038 | NOM-ADHERENT | nom d'adhérent vide |

Sur le serveur, la passerelle se lance par le cron, après l'export de nuit :

```
30 2 * * * cd /opt/passerelle && bin/passerelle --sortie /echange/suivi /echange/erp/APP*.DAT >> /var/log/passerelle.log 2>&1
```

| Code de sortie | Sens |
|---:|---|
| 0 | tout est passé, ou le fichier était déjà traité |
| 1 | lot livré, mais des lignes sont rejetées |
| 2 | lot refusé, rien n'est livré |
| 3 | erreur d'utilisation ou de configuration |

Options : `--sortie`, `--format` (le copybook), `--produits` (le référentiel), `--encodage` (`cp850` par défaut, aussi `latin1` ou `cp1252`), `--force` et `--aide`.

Installation : copier le dossier sur le serveur. Il n'y a rien d'autre à installer.

## Ce que fait la passerelle

1. **Elle lit la mise en page dans le copybook COBOL de l'ERP** ([`formats/apports.cpy`](formats/apports.cpy)), c'est-à-dire la description d'origine de ses enregistrements.
2. **Elle découpe chaque ligne** avec `unpack`, décode les textes depuis CP850 et lit les nombres, virgule implicite et signe compris.
3. **Elle contrôle chaque apport :**
   - clé de l'adhérent ;
   - nom présent ;
   - date réelle et antérieure à l'export ;
   - produit connu ;
   - poids non nul ;
   - humidité plausible ;
   - montant égal à poids × prix ;
   - bon unique dans le lot.
4. **Elle contrôle le lot entier :** un en-tête au début, une fin de lot à la fin, et entre les deux autant d'apports et le même total que ce que la fin de lot annonce.
5. **Elle écrit deux fichiers :**
   - les apports valides, en CSV pour l'outil de suivi ;
   - les rejets, avec le numéro de ligne, le champ, la raison et la ligne d'origine.
6. **Elle tient un journal** des fichiers livrés, reconnus à leur empreinte SHA-256. Si le cron repasse, ou si le même fichier revient sous un autre nom, rien n'est livré deux fois.

## Les choix qui comptent

- **Le format vient du copybook, pas du code.** Les positions et les longueurs ne sont pas recopiées à la main dans le programme, où une erreur d'un caractère décalerait tous les champs suivants. La passerelle lit la description de l'ERP, avec les règles de mise en page de COBOL : colonnes de séquence, commentaires, instructions sur plusieurs lignes, groupes, niveaux 88. Ce qu'elle ne sait pas lire (`COMP-3`, `OCCURS`, `REDEFINES`) est refusé avec la ligne en cause, au lieu d'être mal lu en silence.
- **Le signe caché dans le dernier chiffre.** Par défaut, COBOL range le signe d'un nombre dans le dernier chiffre. Après conversion en ASCII, `00000123M` vaut −12,34 € et `00000123D` vaut +12,34 €. Une lecture naïve prend ces montants pour des erreurs, ou pire, pour des nombres positifs. La passerelle connaît aussi la variante des compilateurs Micro Focus et le signe séparé (`SIGN TRAILING SEPARATE`).
- **Des centimes entiers, jamais de flottants.** Les montants restent des entiers de centimes du début à la fin. Le total de contrôle se compare donc à l'exact, sans écart d'arrondi.
- **Un fichier douteux est refusé en bloc.** Un fichier tronqué pendant le transfert ressemble à un lot plus petit. La fin de lot annonce le nombre d'apports et le total : s'ils ne correspondent pas, rien n'est livré à l'outil de suivi. Le fichier n'entre pas non plus dans le journal, et le passage suivant le reprendra une fois réexporté.
- **Jamais de fichier à moitié écrit.** Les CSV s'écrivent dans des fichiers temporaires, renommés seulement à la fin. L'outil de suivi ne peut pas importer un fichier en cours d'écriture.
- **Ce que les transferts abîment est toléré**, mais pas les données fausses :
  - fins de ligne Windows ;
  - `Ctrl-Z` final des outils DOS ;
  - blancs de fin de ligne supprimés par un transfert FTP ;
  - champs texte jamais remplis (`LOW-VALUES`, des octets nuls).
- **Toutes les erreurs d'une ligne, pas seulement la première.** Une ligne avec une clé fausse et un produit inconnu donne deux rejets. On corrige tout dans l'ERP en une seule fois.
- **Deux fichiers, deux lecteurs :**
  - les apports partent vers une machine : CSV standard (RFC 4180), UTF-8, virgule, dates ISO, point décimal ;
  - les rejets sont lus par une personne dans Excel : point-virgule, BOM, montants avec une virgule.

## Tests

```bash
prove -l t
```

Plus de 250 vérifications, toutes avec les seuls modules de base :

- **Copybook :**
  - le format de l'ERP, champ par champ ;
  - les colonnes de séquence et d'identification ;
  - une instruction sur deux lignes, et deux sur une ligne ;
  - chaque clause refusée, avec son message.
- **Décodage :**
  - les 20 lettres du signe inclus, et la variante Micro Focus ;
  - le signe séparé, devant ou derrière ;
  - les champs vides ou illisibles ;
  - les grands totaux exacts ;
  - l'échappement CSV.
- **Contrôles :**
  - la clé de Luhn ;
  - les années bissextiles, dont 1900 et 2000 ;
  - l'arrondi du montant ;
  - chaque règle, et plusieurs erreurs sur une même ligne.
- **Lots :**
  - un CSV comparé caractère par caractère ;
  - le journal et `--force` ;
  - neuf façons de refuser un lot, avec à chaque fois la preuve que rien n'est livré ;
  - les dégâts des transferts ;
  - l'encodage au choix.
- **Ligne de commande :** les codes de sortie et les messages, sans trace interne de Perl.
- **Modules :** chacun fait partie de Perl 5.10.1.

`outils/generer.pl` fabrique des exports d'essai, au format et dans l'encodage de l'ERP. Avec `--erreurs`, il y glisse une faute de chaque sorte.
