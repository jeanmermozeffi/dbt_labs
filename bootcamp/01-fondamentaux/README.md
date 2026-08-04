# Module 01 — Fondamentaux dbt

## Objectifs

- Comprendre ELT vs ETL et ou dbt se situe.
- Maitriser `ref()` et `source()`, le DAG, et pourquoi ca change tout.
- Connaitre les 4 materialisations de base et quand choisir laquelle.
- Savoir lire l'anatomie d'un projet dbt (`dbt_project.yml`).

## ELT vs ETL, et ou dbt intervient

- **ETL** (Extract-Transform-Load) : on transforme les donnees
  *avant* de les charger dans l'entrepot (Informatica, Talend...).
  La transformation se fait sur un serveur intermediaire.
- **ELT** (Extract-Load-Transform) : on charge les donnees brutes
  telles quelles dans l'entrepot (Fivetran, Airbyte...), PUIS on
  transforme *dans* l'entrepot, en SQL, en utilisant sa puissance de
  calcul. **C'est la ou dbt intervient : dbt ne fait que le "T".**

dbt n'extrait rien, ne charge rien depuis un systeme externe (a part
les seeds, reserves aux petits fichiers de reference — voir plus
bas). Dans ce projet, l'extraction/chargement est simule par
[`postgres/init-scripts/01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql),
qui peuple directement `raw.*` — comme le ferait un outil d'ingestion
en production. Le travail de dbt commence a partir de la.

## `source()` : la frontiere entre "eux" et "nous"

`raw.*` n'appartient pas a dbt : c'est le systeme operationnel. On ne
le reference JAMAIS avec un nom de table en dur — toujours via
`source()`, declare dans un fichier YAML :

```yaml
# models/staging/_staging__sources.yml
sources:
  - name: raw
    schema: raw
    tables:
      - name: customers
      - name: orders
```

```sql
-- models/staging/stg_customers.sql
select * from {{ source('raw', 'customers') }}
```

Pourquoi pas juste `select * from raw.customers` ? Trois raisons
concretes :

1. **Traçabilité du DAG** — `dbt ls --select source:raw.customers+`
   liste tout ce qui depend de cette source. Avec du SQL en dur, dbt
   ne sait pas que `stg_customers` en depend.
2. **Tests et fraicheur** — les tests et la freshness (module 07) ne
   s'appliquent qu'aux sources declarees.
3. **Portabilite** — changer de base/schema source = un seul endroit
   a modifier (le YAML), pas une recherche/remplacement dans du SQL.

## `ref()` : ne jamais coder un nom de table en dur

```sql
-- models/marts/core/dim_customers.sql
select * from {{ ref('stg_customers') }}
```

A la compilation, `{{ ref('stg_customers') }}` devient le nom
pleinement qualifie de la table/vue reellement creee (avec le bon
schema, la bonne base). Regardez le SQL compile :

```bash
dbt compile --select dim_customers
cat target/compiled/dbt_labs/models/marts/core/dim_customers.sql
```

`ref()` est ce qui permet a dbt de construire le **DAG** (graphe
acyclique dirige) : en analysant chaque appel `ref()`/`source()` dans
chaque modele, dbt sait *exactement* dans quel ordre executer les
modeles, et lesquels executer en parallele.

```bash
dbt ls --select +dim_customers --resource-type model   # ses dependances
dbt docs generate && dbt docs serve   # DAG visuel interactif
```

`--resource-type model` n'est pas optionnel ici : sans lui, `dbt ls`
liste **aussi les 80 tests, les sources et les unit tests** du
sous-graphe, et la reponse devient illisible. Voir
[reference-cli.md §3](../reference-cli.md).

## Les 4 materialisations de base

| Materialisation | Objet cree | Quand l'utiliser |
|---|---|---|
| `view` (defaut) | Vue SQL | Staging : leger, toujours a jour, pas de stockage |
| `table` | Table physique | Marts consultes souvent / requetes lourdes |
| `incremental` | Table, mise a jour partielle | Gros volumes, historique qui s'accumule (module 05) |
| `ephemeral` | Rien (CTE inline) | Logique intermediaire jamais interrogee seule |

Dans ce projet, `dbt_project.yml` fixe des defauts par dossier :

```yaml
models:
  dbt_labs:
    staging:
      +materialized: view
    intermediate:
      +materialized: ephemeral
    marts:
      +materialized: table
```

`fct_orders` et `fct_order_items` surchargent ce defaut avec
`materialized='incremental'` directement dans un `{{ config(...) }}`
en tete de fichier — une config au niveau du fichier gagne toujours
sur `dbt_project.yml`.

## Anatomie du projet (`dbt_project.yml`)

Ouvrez [`dbt_project.yml`](../../dbt_project.yml). Points cles :

- `model-paths`, `seed-paths`, `macro-paths`, `snapshot-paths`,
  `test-paths` : ou dbt va chercher chaque type de fichier.
- `models:` / `seeds:` / `snapshots:` : configuration hierarchique
  par nom de projet puis par chemin de dossier (`+materialized`,
  `+schema`, `+group`...). Plus le chemin est specifique, plus il est
  prioritaire.
- `vars:` : variables globales, surchargeables en ligne de commande
  avec `--vars '{"date_spine_start_date": "2024-01-01"}'`.

## Pourquoi le prefixe `+` dans les configs de dossier ?

`+materialized: view` et pas `materialized: view` : le `+` signale a
dbt "ceci est une config", pour la distinguer d'un sous-dossier
litteral qui s'appellerait `materialized`. Vous verrez parfois
l'ancienne syntaxe sans `+` dans de vieux projets — dbt l'accepte
encore mais avec un avertissement de depreciation.

## Premiere execution, commande par commande

> Reference complete des commandes, de la syntaxe `--select` et de la
> lecture des sorties : [reference-cli.md](../reference-cli.md).
> Gardez-la ouverte a cote pendant cette premiere execution.

### 0. Charger l'environnement

```bash
set -a && source .env && set +a
```

`dbt` est un **processus enfant** de votre shell : il n'herite que
des variables **exportees**. `source .env` seul definit les variables
localement sans les exporter — dbt ne les verrait pas et planterait
sur `Env var required but not provided: 'POSTGRES_USER'`. `set -a`
force l'export automatique de tout ce qui est defini ensuite ;
`set +a` desactive ce mode juste apres.

A refaire **dans chaque nouveau terminal**. Verifiez avec
`echo $POSTGRES_USER` : vide = pas charge.

### 1. `dbt seed` — charger les referentiels CSV

```bash
dbt seed
```

Un **seed** est un CSV versionne dans git que dbt charge tel quel en
table. C'est la seule exception au principe "dbt ne fait que le T".
Ici : `data/countries.csv` (7 lignes) et `data/payment_methods.csv`
(4 lignes), utilises plus loin par des tests `relationships`.

Un seed est justifie quand la donnee est **petite**, **stable**, et
**sans proprietaire ailleurs** (referentiels : pays, devises, mapping
de codes). Un export de production ou un fichier qui change chaque
semaine n'est PAS un seed — c'est le travail d'un outil d'ingestion.

Sortie attendue, decodee :

```
Found 15 models, 1 snapshot, ..., 2 seeds, ..., 900 macros, ...
      ^ resultat du PARSE : ce que dbt a compris de vos fichiers.
        Apparait sur TOUTE commande. Les 900 macros viennent de
        dbt-core et des packages, pas de vous (vous en avez ~15).

Concurrency: 4 threads (target='dev')
             ^ threads: 4 dans profiles.yml : jusqu'a 4 noeuds en
               parallele. target='dev' : verifiez toujours cette
               valeur avant une commande destructive.

1 of 2 OK loaded seed file CIC_DWH_seeds.countries [INSERT 7 in 0.05s]
                                ^^^^^^^^^^^^^^^^^^  ^^^^^^^^
                                schema.table REELS  statut renvoye
                                                    par Postgres
```

**Pourquoi `CIC_DWH_seeds` et pas `CIC_DWH` ?** Votre `.env` fixe
`POSTGRES_SCHEMA=CIC_DWH` (le schema de base), `dbt_project.yml`
ajoute `+schema: seeds` pour le dossier des seeds, et
[`macros/generate_schema_name.sql`](../../macros/generate_schema_name.sql)
combine les deux en `CIC_DWH_seeds` hors production. Mecanisme
complet : [reference-cli.md §5](../reference-cli.md), macro detaillee
au [module 04](../04-jinja-macros-avancees/README.md).

### 2. `dbt run --select staging` — construire une couche

```bash
dbt run --select staging
```

`dbt run` execute les modeles : il envoie a Postgres un
`CREATE VIEW` ou `CREATE TABLE` par modele, **dans l'ordre du DAG**.

`--select staging` = "uniquement le dossier `models/staging/`", soit
les 6 modeles `stg_*`. Sans `--select`, dbt construit **tout** le
projet.

Vous verrez 6 lignes `OK created sql view model CIC_DWH_staging.stg_*`
et, en derniere ligne, le bilan :

```
Done. PASS=6 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=6
```

`SKIP` est le compteur qu'on interprete mal : un noeud `SKIP` n'a
aucun probleme en soi, il n'a pas ete execute **parce qu'un parent a
echoue**. Quand vous en voyez, remontez au premier `ERROR`.

### 3. `dbt run --select +dim_customers` — construire avec ses dependances

```bash
dbt run --select +dim_customers
```

Le `+` signifie "et les voisins dans le DAG", et **le cote ou vous le
placez donne la direction** :

| Syntaxe | Signification |
|---|---|
| `dim_customers` | ce modele seul (echoue si ses parents n'existent pas) |
| `+dim_customers` | ce modele **et tous ses ancetres** |
| `dim_customers+` | ce modele **et tous ses descendants** |
| `+dim_customers+` | les deux — l'impact total |

Ici, `+dim_customers` construit 8 modeles : `dim_customers`,
`fct_orders`, les 2 `int_*` et 4 `stg_*`. Avant de lancer un
`--select` complexe, validez-le avec `dbt ls` (aucune ecriture, donc
sans risque) :

```bash
dbt ls --select +dim_customers --resource-type model
```

`--resource-type model` est important : sans lui, `dbt ls` liste
**aussi les 80 tests et les sources**, et la reponse devient
illisible.

### 4. `dbt test --select staging` — verifier

```bash
dbt test --select staging
```

Execute les tests declares en YAML sur les modeles de staging.
**Regle d'or : un test dbt echoue si sa requete SQL retourne au moins
une ligne** — un test cherche des contre-exemples.

### En pratique : `dbt build` plutot que run puis test

```bash
dbt build --select staging
```

`dbt build` fait seed + run + test + snapshot **entrelaces dans
l'ordre du DAG** : il construit `stg_orders`, le teste, et ne
construit `fct_orders` que si les tests de `stg_orders` passent.

`dbt run && dbt test` construit **tout** d'abord, teste ensuite : un
modele fautif contamine tout l'aval avant que vous ne le sachiez.
`dbt run` seul reste utile en dev pour iterer vite sur un modele ;
en CI et en production, utilisez toujours `dbt build`.

## Exercice

`stg_products` expose `unit_price` mais aucune segmentation. Ajoutez
une colonne `price_tier` :
- `unit_price < 30` → `'budget'`
- `unit_price < 80` → `'mid'`
- sinon → `'premium'`

Contraintes : la logique doit vivre dans `stg_products` (c'est une
simple derivation, pas une agregation — donc pas de l'intermediate).
Ajoutez un test `accepted_values` sur la nouvelle colonne.

### Pourquoi cet exercice demande de toucher DEUX fichiers

C'est la dualite fondamentale d'un projet dbt, et elle merite d'etre
enoncee explicitement une bonne fois :

```
stg_products.sql                      _staging__models.yml
----------------                      --------------------
LE CODE                               LES METADONNEES
la transformation elle-meme           ce qu'on AFFIRME sur son resultat
"calcule price_tier comme ceci"       "price_tier ne vaut jamais
                                       autre chose que ces 3 valeurs"
execute par : dbt run                 execute par : dbt test
```

Les deux ne se remplacent pas, ils se completent :

- **Le `.sql` seul** : la colonne existe, mais rien ne garantit son
  contenu. Un `case when` mal ecrit produit des donnees fausses en
  silence — et c'est exactement ce qui etait arrive dans ce repo
  (voir la solution ci-dessous).
- **Le `.yml` seul** : vous decrivez une colonne qui n'existe pas.

Un modele dbt correct, c'est **toujours la paire**. Detail complet de
chaque type de fichier : [reference-fichiers.md](../reference-fichiers.md).

### Solution

```sql
-- models/staging/stg_products.sql (extrait de "renamed")
select
    product_id,
    product_name,
    category,
    unit_price_cents,
    {{ cents_to_dollars('unit_price_cents') }} as unit_price,
    case
        when {{ cents_to_dollars('unit_price_cents') }} < 30 then 'budget'
        when {{ cents_to_dollars('unit_price_cents') }} < 80 then 'mid'
        else 'premium'
    end as price_tier,
    is_active,
    created_at,
    {{ dbt.current_timestamp() }} as loaded_at
from source
```

```yaml
# models/staging/_staging__models.yml
    - name: stg_products
      description: "Catalogue produit, renomme/standardise depuis raw.products."
      columns:
          - name: product_id
            tests: [unique, not_null]
          - name: price_tier          # <-- DANS columns: de stg_products
            tests:
                - not_null
                - accepted_values:
                      arguments:
                          values: ['budget', 'mid', 'premium']
```

#### Les deux bugs reels que contenait ce repo

Cet exercice avait ete fait dans le repo — avec deux erreurs
instructives, corrigees depuis. Elles valent mieux qu'un long
discours.

**Bug 1 — la logique inversee (dans le `.sql`).** La deuxieme
branche du `case` etait `> 80` au lieu de `< 80` :

```sql
when {{ cents_to_dollars('unit_price_cents') }} < 30 then 'budget'
when {{ cents_to_dollars('unit_price_cents') }} > 80 then 'mid'   -- BUG
else 'premium'
```

Resultat en base : un casque a 199,99 $ classe `mid`, un livre a
32,99 $ classe `premium`. Le SQL est valide, le run passe au vert,
et la donnee est fausse. **Aucun outil ne vous previendra** — sauf un
test.

**Bug 2 — le test qui ne s'execute jamais (dans le `.yml`).** Le test
`accepted_values` avait ete ajoute, mais indente **au niveau des
modeles** au lieu d'etre sous `columns:` de `stg_products` :

```yaml
models:
    - name: stg_products
      columns:
          - name: product_id
            tests: [unique, not_null]

    - name: price_tier          # <-- dbt lit "un MODELE nomme price_tier"
      tests:
          - accepted_values: ...
```

dbt ne dit rien. Pas d'erreur, pas d'avertissement, `dbt parse`
passe. Mais le test n'existe pas :

```bash
$ dbt ls --select stg_products --resource-type test
dbt_labs.staging.dbt_expectations_..._unit_price__0
dbt_labs.staging.not_null_stg_products_product_id
dbt_labs.staging.unique_stg_products_product_id
# 3 tests. Pas de trace de price_tier.
```

Apres correction : 5 tests, et le compteur global du projet passe de
78 a 80.

**Le reflexe a prendre a vie** : apres avoir ajoute un test en YAML,
verifiez qu'il **existe** avant de croire qu'il **passe**.

```bash
dbt ls --select <modele> --resource-type test
```

Un `dbt test` qui affiche `PASS=3` alors que vous en attendiez 4
n'est pas un succes : c'est un echec silencieux.

Pourquoi c'est bien place en staging et pas ailleurs : `price_tier`
est une **reecriture 1-pour-1** d'une colonne existante (pas de
jointure, pas d'agregation, pas de logique multi-tables) — exactement
la responsabilite de la couche staging (module 02). La mettre dans un
mart forcerait tout consommateur du mart a refaire ce calcul lui-meme
s'il en a besoin ailleurs ; la mettre en staging la rend disponible a
TOUT le reste du DAG en aval, gratuitement.

Verifiez :

```bash
dbt run --select stg_products
dbt test --select stg_products
```

## Suite

→ [Module 02 — Modelisation dimensionnelle](../02-modelisation-dimensionnelle/README.md)
