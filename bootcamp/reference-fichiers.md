# Reference — Quel fichier fait quoi

Un projet dbt melange une dizaine de types de fichiers. La question
que tout le monde se pose au premier exercice — *"pourquoi dois-je
toucher DEUX fichiers pour ajouter une colonne ?"* — a une reponse
precise, et c'est le sujet de ce document.

---

## 1. La dualite fondamentale : `.sql` = quoi construire, `.yml` = quoi declarer

C'est **le** concept a integrer avant tout le reste.

```
   models/staging/stg_products.sql        models/staging/_staging__models.yml
   ------------------------------        -----------------------------------
   LE CODE                                LES METADONNEES
   La transformation elle-meme            Ce qu'on affirme a propos du resultat

   select                                 - name: stg_products
       product_id,                          description: "Catalogue produit"
       unit_price,                          columns:
       case ... end as price_tier             - name: product_id
   from source                                  tests: [unique, not_null]
                                               - name: price_tier
   -> produit une VUE en base                     tests:
                                                    - accepted_values: ...

   Execute par : dbt run                  Execute par : dbt test
```

**Les deux fichiers ne se remplacent pas, ils se completent :**

- Le `.sql` seul : votre colonne existe, mais **rien ne garantit**
  qu'elle contient les valeurs attendues. Un `case when` mal ecrit
  produit des donnees fausses en silence.
- Le `.yml` seul : vous declarez une colonne qui **n'existe pas**.
  Le test echouera (ou pire, sera ignore — voir le piege ci-dessous).

Un modele dbt correct, c'est **toujours la paire**. C'est pour ca
que les exercices du bootcamp demandent systematiquement les deux.

### Le nom du fichier `.sql` EST le nom du modele

Il n'y a aucun champ "nom du modele" dans le SQL. `stg_products.sql`
-> le modele s'appelle `stg_products`, referencable par
`{{ ref('stg_products') }}`. Renommer le fichier renomme le modele
et casse tous les `ref()` qui pointent dessus.

Le `.yml`, lui, ne fait que **s'accrocher** a ce nom via `- name:`.
S'il ne correspond a aucun fichier `.sql`... voir tout de suite.

### Le piege qui ne fait AUCUN bruit : une entree YAML mal indentee

Ce projet contenait exactement ce bug (corrige depuis) :

```yaml
models:
    - name: stg_products
      description: "Catalogue produit..."
      columns:
          - name: product_id
            tests: [unique, not_null]

    - name: price_tier          # <-- INDENTE AU NIVEAU DES MODELES
      tests:                    #     dbt comprend "un modele nomme price_tier"
          - accepted_values:
                arguments:
                    values: ['budget', 'mid', 'premium']
```

L'intention etait "la colonne `price_tier` de `stg_products`". Ce que
dbt a compris : "un modele nomme `price_tier`". Consequence :

```bash
$ dbt parse
# ... aucun avertissement. Aucune erreur.

$ dbt ls --select stg_products --resource-type test
dbt_labs.staging.dbt_expectations_expect_column_values_to_be_between_stg_products_unit_price__0
dbt_labs.staging.not_null_stg_products_product_id
dbt_labs.staging.unique_stg_products_product_id
# 3 tests. Le test accepted_values sur price_tier N'EXISTE PAS.
```

Le test etait ecrit, revu, commite — et n'a jamais tourne. La bonne
version, indentee sous `columns:` du bon modele :

```yaml
    - name: stg_products
      description: "Catalogue produit..."
      columns:
          - name: product_id
            tests: [unique, not_null]
          - name: price_tier          # <-- DANS columns: de stg_products
            tests:
                - accepted_values:
                      arguments:
                          values: ['budget', 'mid', 'premium']
```

**Le reflexe a prendre a vie** : apres avoir ajoute un test en YAML,
verifiez qu'il existe vraiment.

```bash
dbt ls --select <mon_modele> --resource-type test
```

Le compte doit avoir augmente. `dbt test --select mon_modele` qui
affiche "PASS=3" alors que vous en attendiez 4 est un **echec
silencieux**, pas un succes.

---

## 2. Carte du projet

```
dbt_labs/
│
├── dbt_project.yml          LE fichier central : nom du projet, chemins,
│                            configs par defaut par dossier (materialisation,
│                            schema, groupe), variables globales
├── packages.yml             dependances (dbt_utils, dbt_expectations, codegen)
├── package-lock.yml         versions exactes resolues -> A COMMITER
├── selectors.yml            selections nommees reutilisables (module 09)
├── profiles.yml.example     modele de connexion, SANS secret -> commite
├── .env                     vos identifiants -> JAMAIS commite
├── compose.yml              le Postgres local (le "systeme source" simule)
│
├── models/                  le coeur : vos transformations
│   ├── groups.yml           groupes de gouvernance + proprietaires (module 10)
│   ├── staging/
│   │   ├── stg_*.sql                 1 modele = 1 source, renommage pur
│   │   ├── _staging__sources.yml     DECLARE les tables raw.* + leurs tests
│   │   ├── _staging__models.yml      DECRIT/TESTE les modeles stg_*
│   │   └── _staging__unit_tests.yml  tests de LOGIQUE (donnees fictives)
│   ├── intermediate/
│   │   ├── int_*.sql
│   │   └── _intermediate__models.yml
│   └── marts/
│       ├── _marts__exposures.yml     qui consomme ces marts (BI, rapports)
│       ├── core/
│       │   ├── dim_*.sql / fct_*.sql
│       │   ├── _core__models.yml
│       │   └── _core__semantic_models.yml   metriques (module 08)
│       └── returns/
│
├── data/                    seeds : CSV versionnes, charges par `dbt seed`
│                            (dossier non conventionnel : seed-paths dans
│                             dbt_project.yml ; le defaut dbt est seeds/)
├── macros/                  fonctions Jinja reutilisables
│   ├── cents_to_dollars.sql
│   ├── generate_schema_name.sql       surcharge d'une macro dbt interne
│   └── generic_tests/                 vos tests reutilisables ({% test %})
├── tests/                   tests SINGULIERS : 1 fichier .sql = 1 regle metier
├── snapshots/               historisation SCD2 (module 06)
├── analyses/                SQL compile mais JAMAIS execute (module 04)
│
├── target/          <-- GENERE. jamais commite, `dbt clean` le supprime
├── dbt_packages/    <-- GENERE par `dbt deps`
└── logs/            <-- GENERE. logs/dbt.log = le dernier run complet
```

---

## 3. Les fichiers YAML, un par un

Tous portent l'extension `.yml`, mais ils declarent des choses
totalement differentes. Le nom du fichier n'a **aucune importance
technique** — dbt lit tous les `.yml` de `models/` et regarde la
**cle de premier niveau** pour savoir de quoi il s'agit.

| Cle de 1er niveau | Ce qu'elle declare | Fichier de ce projet |
|---|---|---|
| `sources:` | tables externes a dbt (`raw.*`) + tests + freshness | `_staging__sources.yml` |
| `models:` | description, tests, contrats, configs des modeles | `_staging__models.yml`, `_core__models.yml` |
| `unit_tests:` | tests de logique avec donnees fictives | `_staging__unit_tests.yml` |
| `exposures:` | consommateurs en aval (dashboard, rapport) | `_marts__exposures.yml` |
| `semantic_models:` / `metrics:` | couche semantique MetricFlow | `_core__semantic_models.yml` |
| `groups:` | domaines + proprietaires | `groups.yml` |
| `snapshots:` | config des snapshots (dbt >= 1.9) | dans `snapshots/` |
| `seeds:` | description/tests des CSV | — |

Deux fichiers peuvent contenir plusieurs cles (`models:` **et**
`unit_tests:` dans le meme fichier, c'est legal). La separation en
fichiers distincts est une **convention de lisibilite**, pas une
contrainte de dbt.

### La convention de nommage `_dossier__type.yml`

```
_staging__sources.yml
^        ^^
|        ||__ type de contenu
|        |___ double underscore = separateur
|____________ underscore initial
```

- **`_` initial** : dans un explorateur trie alphabetiquement, les
  fichiers YAML remontent en haut du dossier. Vous voyez les
  definitions avant les 6 fichiers SQL.
- **`__` (double)** : separe le dossier du type. Evite que
  `staging/sources.yml` et `marts/sources.yml` soient confondus dans
  une recherche, un diff de PR ou une discussion.

Ce n'est pas impose par dbt — c'est le
[style guide dbt Labs](https://docs.getdbt.com/best-practices/how-we-style/2-how-we-style-our-sql),
suivi par ce projet.

---

## 4. Les fichiers de configuration racine

### `dbt_project.yml` — la config hierarchique

C'est le seul fichier **obligatoire** d'un projet dbt. Le mecanisme
central a comprendre : **la config descend par les dossiers, et le
plus specifique gagne.**

```yaml
models:
  dbt_labs:              # nom du projet (obligatoire a ce niveau)
    +materialized: view  # defaut pour TOUS les modeles
    +group: core

    staging:             # = le dossier models/staging/
      +materialized: view
      +schema: staging

    marts:               # = le dossier models/marts/
      +materialized: table
      +schema: marts
      returns:           # = models/marts/returns/, herite de marts
        +group: returns  # ... mais surcharge le groupe
```

Ordre de priorite, du plus faible au plus fort :

```
defaut dbt  <  dbt_project.yml (dossier parent)  <  dbt_project.yml (sous-dossier)
            <  fichier .yml de proprietes  <  {{ config() }} dans le .sql
```

C'est pour ca que `fct_orders.sql` peut declarer
`materialized='incremental'` dans son `{{ config() }}` malgre le
`+materialized: table` du dossier `marts` : la config au niveau du
fichier gagne toujours.

**Le prefixe `+`** signale "ceci est une config" et non un
sous-dossier qui s'appellerait litteralement `materialized`. dbt
accepte encore l'ancienne syntaxe sans `+`, avec un avertissement de
depreciation. Utilisez toujours `+` dans du code neuf.

### `profiles.yml` vs `dbt_project.yml` : la separation qui compte

| | `dbt_project.yml` | `~/.dbt/profiles.yml` |
|---|---|---|
| Ou | dans le repo, **commite** | hors du repo, **jamais commite** |
| Quoi | **quoi** construire et comment | **ou** se connecter |
| Contient | chemins, materialisations, schemas logiques, vars | host, user, password, dbname, threads, targets |
| Partage | identique pour toute l'equipe | propre a chaque developpeur |

Le lien entre les deux : `profile: 'dbt_labs'` dans
`dbt_project.yml` designe le bloc `dbt_labs:` de `profiles.yml`. Les
deux noms doivent correspondre exactement — sinon
`Could not find profile named 'dbt_labs'`.

### `packages.yml` et `package-lock.yml`

```yaml
# packages.yml — ce que VOUS demandez (plages de versions)
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
```

`dbt deps` resout ces plages, telecharge dans `dbt_packages/`, et
ecrit les versions **exactes** obtenues dans `package-lock.yml`.

- `packages.yml` : **a commiter** (l'intention).
- `package-lock.yml` : **a commiter aussi** (la reproductibilite —
  meme role que `package-lock.json` en npm ou `poetry.lock`).
- `dbt_packages/` : **jamais commite** (regenerable par `dbt deps`).

### `.env` et la securite

```
POSTGRES_PASSWORD=8whZSG...
```

Ce fichier est dans `.gitignore` et doit y rester. `profiles.yml` ne
contient **aucun mot de passe en clair** : uniquement des appels
`env_var()` qui lisent l'environnement. Voir
[reference-cli.md §6](reference-cli.md) pour le mecanisme
`set -a && source .env && set +a` et pourquoi il est necessaire.

---

## 5. Les dossiers generes (ne jamais commiter, ne jamais editer)

| Dossier | Genere par | Contenu utile |
|---|---|---|
| `target/compiled/` | `compile`, `run`, `build` | **le SQL reel envoye a la base** — votre meilleur outil de debug |
| `target/run/` | `run`, `build` | le SQL avec le `CREATE TABLE ... AS` autour |
| `target/manifest.json` | toute commande | l'etat complet du projet ; base du slim CI (module 09) et de l'observabilite (module 11) |
| `target/run_results.json` | `run`, `test`, `build` | duree et statut de chaque noeud du dernier run |
| `target/catalog.json` | `docs generate` | colonnes/types **reels** lus dans l'entrepot |
| `dbt_packages/` | `deps` | code source des packages |
| `logs/dbt.log` | toute commande | log complet, meme apres fermeture du terminal |

`dbt clean` supprime `target/` et `dbt_packages/` (liste definie par
`clean-targets:` dans `dbt_project.yml`).

---

## 6. "Je veux faire X — quel fichier ?"

| Je veux... | Fichier a editer |
|---|---|
| ajouter/modifier une colonne | le `.sql` du modele **+** le `.yml` de proprietes du dossier |
| tester une colonne | le `.yml` de proprietes (`columns:` -> `tests:`) |
| tester une regle metier croisant 2 modeles | un nouveau `.sql` dans `tests/` (test singulier) |
| reutiliser un test sur plusieurs colonnes | `macros/generic_tests/` puis reference par nom en YAML |
| tester la logique sans toucher la base | `_*__unit_tests.yml` (cle `unit_tests:`) |
| declarer une nouvelle table source | `_staging__sources.yml` (cle `sources:`) |
| changer view -> table pour tout un dossier | `dbt_project.yml`, `+materialized:` |
| changer view -> table pour UN modele | `{{ config(materialized='table') }}` en tete du `.sql` |
| ajouter une fonction SQL reutilisable | `macros/*.sql` |
| ajouter un referentiel statique | un CSV dans `data/` + `dbt seed` |
| historiser une dimension qui change | `snapshots/*.sql` |
| documenter qu'un dashboard depend de mes marts | `_marts__exposures.yml` |
| explorer du SQL sans creer d'objet | `analyses/*.sql` |
| changer d'utilisateur/mot de passe | `.env` (jamais un `.yml`) |
| ajouter un environnement (`prod`, `ci`) | `~/.dbt/profiles.yml`, sous `outputs:` |

---

Voir aussi : [reference-cli.md](reference-cli.md) (commandes,
selection, lecture des sorties) · [glossaire.md](glossaire.md)
