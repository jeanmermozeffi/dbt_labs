# Reference — La CLI dbt : commandes, selection, lecture des sorties

Ce document est le **mode d'emploi de l'outil**. Les modules du
bootcamp expliquent *quoi* construire et *pourquoi* ; celui-ci
explique *comment piloter dbt* et surtout **comment lire ce qu'il
vous repond**.

A lire une fois entre le [module 00](00-setup/README.md) et le
[module 01](01-fondamentaux/README.md), puis a garder ouvert comme
antiseche.

---

## 1. Le modele mental : dbt est un compilateur, pas une base de donnees

dbt ne stocke rien, ne calcule rien. A chaque commande, il fait
toujours les memes 3 etapes :

```
   VOS FICHIERS                dbt                      VOTRE ENTREPOT
   ------------                ---                      --------------
   models/*.sql       1. PARSE : lit tous les
   models/*.yml          fichiers, resout ref()/
   macros/*.sql          source(), construit le DAG
   dbt_project.yml            |
   packages.yml               v
                      2. COMPILE : remplace le Jinja
                         ({{ ref() }}, macros, if...)
                         par du SQL pur
                         -> target/compiled/**.sql
                              |
                              v
                      3. EXECUTE : envoie ce SQL a
                         l'entrepot, dans l'ordre du    ---> CREATE VIEW ...
                         DAG, sur N threads                  CREATE TABLE ...
                                                             INSERT INTO ...
```

Consequences pratiques a retenir :

- **Une erreur de "Parsing Error" arrive avant toute connexion a la
  base** — c'est un probleme de fichiers/config, pas de donnees.
  (C'est le cas de `Env var required but not provided:
  'POSTGRES_USER'` : dbt n'a meme pas essaye de joindre Postgres.)
- **Le SQL reellement execute est sur votre disque**, lisible :
  `target/compiled/dbt_labs/models/...`. En cas de doute sur ce que
  fait une macro, ne devinez pas — lisez le compile.
- **dbt ne "voit" pas vos donnees pendant la compilation** (sauf
  `run_query`, module 04). Il ne connait que la structure declaree.

---

## 2. Les commandes, une par une

| Commande | Ce qu'elle fait | Ecrit-elle dans l'entrepot ? |
|---|---|---|
| `dbt debug` | Teste la connexion + la config (profil, dossiers, deps) | Non |
| `dbt deps` | Telecharge les packages de `packages.yml` dans `dbt_packages/` | Non |
| `dbt parse` | Etape 1 seulement : produit `target/manifest.json` | Non |
| `dbt compile` | Etapes 1+2 : produit le SQL final dans `target/compiled/` | Non |
| `dbt ls` | Liste les objets selectionnes (ne les execute pas) | Non |
| `dbt seed` | Charge les CSV de `data/` en tables | **Oui** |
| `dbt run` | Construit les modeles (`CREATE VIEW/TABLE`, `INSERT`) | **Oui** |
| `dbt test` | Execute les tests (chaque test = un `SELECT`) | Non (sauf `store_failures`) |
| `dbt snapshot` | Met a jour les snapshots SCD2 de `snapshots/` | **Oui** |
| `dbt build` | seed + run + test + snapshot, **dans l'ordre du DAG** | **Oui** |
| `dbt source freshness` | Verifie l'age des donnees sources | Non |
| `dbt docs generate` | Produit `catalog.json` (introspecte l'entrepot) | Non |
| `dbt docs serve` | Sert la doc + le DAG visuel sur localhost:8080 | Non |
| `dbt show --select m` | Affiche un apercu du resultat d'un modele | Non |
| `dbt retry` | Rejoue uniquement ce qui a echoue au dernier run | **Oui** |
| `dbt clean` | Supprime `target/` et `dbt_packages/` | Non |

### `dbt build` vs `dbt run` + `dbt test` : la difference qui compte

Ce n'est **pas** juste un raccourci. Comparez :

```bash
# A : sequentiel par type
dbt run && dbt test

# B : entrelace par noeud
dbt build
```

- **A** construit les 15 modeles, PUIS teste les 15 modeles. Si
  `stg_orders` est corrompu, `fct_orders` est quand meme construit
  par-dessus des donnees fausses. Vous ne l'apprenez qu'a la fin.
- **B** construit `stg_orders`, teste `stg_orders`, et **ne
  construit `fct_orders` que si les tests de `stg_orders` passent**.
  Un modele dont un parent a echoue passe en `SKIP`.

**En production, utilisez toujours `dbt build`.** `dbt run` seul est
un outil de developpement local (iterer vite sur un modele sans
attendre les tests).

Attention (piege reel, voir [module 06](06-snapshots-scd/README.md)) :
`dbt build` inclut bien `snapshot`, mais l'ordre est celui du DAG —
si un snapshot doit tourner *avant* tout le reste (cas courant : on
historise la source avant de la transformer), il faut un
`dbt snapshot` explicite en amont. C'est pour ca que la CI de ce
projet fait `dbt deps && dbt seed && dbt build && dbt snapshot`.

### `dbt seed` : ce que c'est vraiment

Un **seed** est un CSV **versionne dans git** que dbt charge tel quel
en table. C'est la seule exception au "dbt ne fait que le T".

Dans ce projet : [`data/countries.csv`](../data/countries.csv) (7
lignes) et [`data/payment_methods.csv`](../data/payment_methods.csv)
(4 lignes).

**Pourquoi le dossier s'appelle `data/` et pas `seeds/`** : c'est
configure dans `dbt_project.yml` par `seed-paths: ["data"]`. Le
defaut dbt est `seeds/` ; ce projet a garde `data/`, ce qui est
legal mais non conventionnel — si vous demarrez un projet neuf,
gardez `seeds/`.

Un seed est legitime quand les 3 conditions sont reunies :

1. **Petit** (quelques centaines de lignes max — c'est du `INSERT`
   ligne par ligne, pas un chargement en masse).
2. **Stable** (referentiels : pays, devises, mapping de codes).
3. **Sans proprietaire ailleurs** — si la donnee existe deja dans un
   systeme source, c'est une `source()`, pas un seed.

Un seed n'est PAS : un export de production, un fichier qui change
toutes les semaines, ou 500 Mo de donnees. Ces cas relevent d'un
outil d'ingestion (Fivetran, Airbyte, un `COPY` SQL).

Le typage est controlable depuis `dbt_project.yml` — sinon dbt
devine, et devine parfois mal (un code pays `NA` pour Namibie lu
comme `NULL`, un code postal `01234` lu comme l'entier `1234`) :

```yaml
seeds:
  dbt_labs:
    +schema: seeds
    countries:
      +column_types:
        country_code: varchar(2)   # pas de devinette possible
```

---

## 3. La syntaxe de selection (`--select`)

C'est la partie la plus rentable de ce document : la meme grammaire
sert a `run`, `test`, `build`, `ls`, `compile`, `docs generate`.

### 3.1 Selectionner par nom

```bash
dbt run --select stg_orders              # un modele
dbt run --select stg_orders stg_payments # deux (espace = OU / union)
dbt run --exclude stg_returns            # tout sauf
```

### 3.2 Les operateurs de graphe : `+`

Le `+` veut dire "et les voisins dans le DAG". **Le cote ou vous
mettez le `+` indique la direction** :

```
        stg_orders  ->  int_order_amounts  ->  fct_orders  ->  dim_customers
        (amont / parents)                       (aval / enfants)
```

| Syntaxe | Signification | Cas d'usage |
|---|---|---|
| `fct_orders` | ce modele seul | iterer sur un modele |
| `+fct_orders` | ce modele **et tous ses ancetres** | "construis tout ce dont j'ai besoin" |
| `fct_orders+` | ce modele **et tous ses descendants** | "j'ai change ce modele, qu'est-ce que je casse ?" |
| `+fct_orders+` | ancetres **et** descendants | l'impact total |
| `2+fct_orders` | ancetres, mais **2 niveaux max** | limiter sur un gros DAG |
| `@fct_orders` | ses descendants **+ tous les ancetres de ces descendants** | reconstruire un sous-graphe complet et coherent |

Le cas `@` merite un mot : si vous reconstruisez `fct_orders+`, ses
enfants sont recalcules — mais leurs *autres* parents, eux, ne le
sont pas, et peuvent etre perimes. `@` garantit que tout ce qui est
recalcule l'est a partir de parents frais. C'est le selecteur des
"rattrapages" apres un incident.

### 3.3 Les methodes : `methode:valeur`

```bash
dbt run  --select path:models/staging          # par chemin de dossier
dbt run  --select staging                      # raccourci equivalent (nom de dossier)
dbt test --select test_type:unit               # unit tests seulement
dbt test --select test_type:singular           # tests de tests/*.sql
dbt run  --select tag:daily                    # par tag pose en config
dbt run  --select config.materialized:incremental
dbt ls   --select source:raw.customers+        # tout ce qui descend d'une source
dbt run  --select exposure:executive_revenue_dashboard  # ce qui alimente un dashboard
dbt build --select state:modified+ --state ./state      # slim CI (module 09)
dbt ls   --select group:returns                # par groupe de gouvernance (module 10)
```

### 3.4 Union (espace) vs intersection (virgule)

C'est **la** subtilite qui piege tout le monde :

```bash
dbt run --select staging marts        # ESPACE = union  -> staging OU marts
dbt run --select staging,tag:hourly   # VIRGULE = inter -> staging ET tag hourly
```

Exemple concret utile : "tous les modeles incrementaux des marts"

```bash
dbt run --select marts,config.materialized:incremental
```

### 3.5 Le piege de `dbt ls`

```bash
dbt ls --select +dim_customers
```

Cette commande, telle quelle, liste **aussi les 78 tests, les
sources, les unit tests** — pas seulement les modeles. Pour repondre
a la question "de quels modeles est-ce que je depends ?" :

```bash
dbt ls --select +dim_customers --resource-type model
```

```
dbt_labs.marts.core.dim_customers
dbt_labs.marts.core.fct_orders
dbt_labs.intermediate.int_order_amounts
dbt_labs.intermediate.int_payments_pivoted
dbt_labs.staging.stg_customers
dbt_labs.staging.stg_order_items
dbt_labs.staging.stg_orders
dbt_labs.staging.stg_payments
```

La, c'est lisible : `dim_customers` a besoin de 7 modeles en amont.
Autres valeurs utiles : `--resource-type test|source|seed|snapshot|exposure`.

Astuce : `dbt ls` est **gratuit et sans risque** (aucune ecriture).
Prenez le reflexe de valider un `--select` complexe avec `dbt ls`
AVANT de le passer a `dbt run` ou `dbt build`.

---

## 4. Lire la sortie de dbt

Reprenons **exactement** la sortie qui vous a fait tiquer, annotee :

```
11:02:04  Running with dbt=1.10.13
```
> Version de dbt-core. Utile a citer dans toute recherche/issue : le
> comportement de `arguments:`, `microbatch`, `unit_tests` depend de
> cette version.

```
11:02:04  Registered adapter: postgres=1.9.1
```
> L'**adapter** est le traducteur dbt -> dialecte SQL de votre
> entrepot. C'est lui qui sait que sur Postgres `merge` n'existe pas
> (module 05) ou comment ecrire un `CREATE INDEX`. Si vous voyez
> `duckdb` ici, vous etes dans le mauvais projet.

```
11:02:05  Found 15 models, 1 snapshot, 1 analysis, 78 data tests, 2 seeds,
          6 sources, 2 exposures, 5 metrics, 900 macros, 2 groups,
          2 semantic models, 3 unit tests
```
> **C'est le resultat de l'etape PARSE.** dbt a lu tous vos fichiers
> et vous dit ce qu'il a compris. C'est votre premier controle :
>
> - Vous venez d'ajouter un modele et le compte n'a pas bouge ? Le
>   fichier est au mauvais endroit ou mal nomme.
> - **`900 macros`** n'est pas anormal : ~15 viennent de vous
>   (`macros/`), tout le reste vient de dbt-core lui-meme et des
>   packages (`dbt_utils`, `dbt_expectations`, `codegen`). Ne
>   cherchez pas 900 fichiers.
> - Cette ligne apparait sur **toutes** les commandes, meme
>   `dbt seed` : dbt parse toujours le projet entier avant d'agir.

```
11:02:05  Concurrency: 4 threads (target='dev')
```
> - `4 threads` vient de `threads: 4` dans `~/.dbt/profiles.yml` :
>   dbt executera jusqu'a 4 noeuds **en parallele**, quand le DAG le
>   permet (des noeuds sans dependance entre eux). Augmentez si votre
>   entrepot encaisse ; c'est le principal levier de vitesse gratuit.
> - `target='dev'` : quel bloc de `outputs:` est utilise. **Verifiez
>   toujours cette valeur avant une commande destructive** — c'est
>   votre garde-fou contre un `--full-refresh` en prod.

```
11:02:05  1 of 2 START seed file dbt_jeff_seeds.countries ......... [RUN]
11:02:05  1 of 2 OK loaded seed file dbt_jeff_seeds.countries ..... [INSERT 7 in 0.05s]
```
> - `1 of 2` : noeud 1 sur les 2 selectionnes. Ce n'est PAS un ordre
>   chronologique garanti — avec 4 threads, `2 of 2` peut finir avant
>   `1 of 2` (c'est visible dans votre propre sortie).
> - `dbt_jeff_seeds.countries` = **`schema.table` reellement ecrits en
>   base**. C'est l'information la plus importante de la ligne, et la
>   source de confusion n°1 : voir la section 5 ci-dessous.
> - `[INSERT 7 in 0.05s]` : le **statut SQL renvoye par Postgres**,
>   pas un message dbt. `INSERT 7` = 7 lignes inserees (le CSV en a
>   7). Vous verrez selon les cas : `CREATE VIEW`, `SELECT 1`
>   (creation de table via CTAS), `INSERT 0 0` (zero ligne — normal
>   sur un run incremental sans nouveaute, suspect sinon).

```
11:02:05  Finished running 2 seeds in 0 hours 0 minutes and 0.26 seconds (0.26s).
```

Et sur un `dbt run`, la ligne finale qu'il faut lire en priorite :

```
Done. PASS=6 WARN=0 ERROR=0 SKIP=0 NO-OP=0 TOTAL=6
```

| Compteur | Signification | Reaction |
|---|---|---|
| `PASS` | reussi | — |
| `WARN` | test en `severity: warn` echoue | a investiguer, ne bloque pas |
| `ERROR` | echec dur | corriger |
| **`SKIP`** | **non execute car un parent a echoue** | **cherchez l'ERROR en amont, pas ici** |
| `NO-OP` | rien a faire (ex. modele desactive) | — |

`SKIP` est le compteur qu'on interprete mal : un modele `SKIP` n'a
aucun probleme en soi. Remontez au premier `ERROR` du log.

### Regler le niveau de detail

```bash
dbt run --select fct_orders --debug        # tout le SQL emis + reponses
dbt run --quiet                            # uniquement les erreurs
dbt run --log-format json                  # exploitable par un outil (module 11)
```

Et dans tous les cas, le log complet du dernier run est toujours
dans `logs/dbt.log`, meme si vous avez ferme le terminal.

---

## 5. "Ou sont parties mes tables ?" — la resolution de schema

C'est LA question qui bloque tout le monde au premier `dbt seed`.
Vous avez ecrit `POSTGRES_SCHEMA=dbt_jeff` dans `.env`, et dbt
annonce `dbt_jeff_seeds.countries`. D'ou sort ce suffixe ?

Trois ingredients se combinent :

```
1. .env                     POSTGRES_SCHEMA=dbt_jeff
        |
        v
2. ~/.dbt/profiles.yml      schema: "{{ env_var('POSTGRES_SCHEMA') }}"
                            -> target.schema = "dbt_jeff"     (le schema de BASE)
        |
        v
3. dbt_project.yml          seeds:   +schema: seeds          (le schema CUSTOM)
                            staging: +schema: staging
                            marts:   +schema: marts
        |
        v
4. macros/generate_schema_name.sql   decide comment 2 et 3 se combinent
        |
        v
   RESULTAT en dev :  dbt_jeff_seeds, dbt_jeff_staging, dbt_jeff_marts
   RESULTAT en prod :  seeds, staging, marts     (sans prefixe)
```

La regle appliquee par
[`macros/generate_schema_name.sql`](../macros/generate_schema_name.sql)
(c'est le snippet standard recommande par dbt Labs, detaille au
[module 04](04-jinja-macros-avancees/README.md)) :

- pas de `+schema` declare -> `target.schema` tel quel ;
- `+schema` declare et `target = prod` -> **le custom seul**
  (`marts`) : des noms propres en production ;
- `+schema` declare et tout autre target -> **`target.schema` +
  `_` + custom** (`dbt_jeff_marts`) : chaque developpeur travaille
  dans son propre espace, sans se marcher dessus.

`POSTGRES_SCHEMA` designe donc **votre bac a sable personnel**, pas
l'entrepot : convention `dbt_<prenom>`. Et il n'a **pas de valeur par
defaut** dans `profiles.yml`, volontairement — un defaut partage
(`dbt_dev`) ferait silencieusement collisionner deux developpeurs
distraits, alors qu'une variable manquante echoue net :

```
Parsing Error
  Env var required but not provided: 'POSTGRES_SCHEMA'
```

Pour verifier a quel schema un noeud est destine **sans rien
executer** :

```bash
dbt ls --resource-type model --output json --output-keys "name schema"
{"schema": "dbt_jeff_marts", "name": "dim_customers"}
{"schema": "dbt_jeff_staging", "name": "stg_orders"}
```

C'est la facon la plus rapide de repondre a "ou ca va atterrir ?"
avant un run, et de comparer deux targets (`--target prod`).

Verifiez a tout moment ce qui existe reellement :

```bash
set -a && source .env && set +a
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" dbt_labs_postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "select table_schema, table_name from information_schema.tables
      where table_schema not in ('pg_catalog','information_schema')
      order by 1,2;"
```

Sur ce projet, apres un `dbt build` complet, vous devez voir 4
schemas : `raw` (votre source simulee), `dbt_jeff_seeds`,
`dbt_jeff_staging`, `dbt_jeff_marts`.

**Le reflexe general** : ne cherchez jamais vos tables "au jugé".
Le nom exact est ecrit dans la sortie de dbt (`schema.table` apres
`START`/`OK`), et dans le SQL compile de `target/compiled/`.

---

## 6. `set -a && source .env && set +a` : pourquoi, vraiment

Cette ligne revient avant chaque commande du bootcamp. Decomposee :

| Element | Role |
|---|---|
| `source .env` | execute le fichier `.env` **dans le shell courant** : les lignes `CLE=valeur` deviennent des variables du shell |
| `set -a` | active le mode "allexport" : **toute** variable definie ensuite est automatiquement **exportee** |
| `set +a` | desactive ce mode (on ne veut pas exporter tout ce qu'on tapera apres) |

Le point crucial est la difference **variable de shell** vs
**variable d'environnement** :

```bash
POSTGRES_USER=admin_dbt_labs        # variable de SHELL : visible par vous seul
export POSTGRES_USER=admin_dbt_labs # variable d'ENVIRONNEMENT : heritee par
                                    # tous les processus enfants
```

`dbt` est un **processus enfant** de votre shell. Il ne voit que
l'environnement exporte. Sans `set -a`, `source .env` definit bien
les variables... mais dbt ne les recoit pas, et `env_var('POSTGRES_USER')`
plante avec :

```
Parsing Error
  Env var required but not provided: 'POSTGRES_USER'
```

C'est exactement cette erreur, et elle est **volontairement fatale** :
`env_var()` sans valeur par defaut fait echouer la compilation
plutot que de laisser dbt se connecter avec un identifiant vide ou
un mauvais mot de passe (voir [module 00](00-setup/README.md)).

Trois choses a savoir :

1. **La portee est le terminal.** Nouvel onglet = nouveau shell =
   il faut refaire `set -a && source .env && set +a`. Ce n'est pas
   persistant, et c'est voulu.
2. **Verifier au lieu de deviner** : `echo $POSTGRES_USER`. Vide =
   pas charge.
3. **Alternative confortable** : [`direnv`](https://direnv.net/)
   charge/decharge automatiquement le `.env` en entrant/sortant du
   dossier. Evitez en revanche de mettre `source .env` dans votre
   `~/.zshrc` : vous auriez en permanence des identifiants de base
   de donnees dans tous vos shells.

---

## 7. Les 7 erreurs que vous allez rencontrer

| Message | Cause reelle | Correctif |
|---|---|---|
| `Env var required but not provided: 'X'` | `.env` pas charge dans CE terminal | `set -a && source .env && set +a` |
| `Connection refused` / `could not connect` | conteneur arrete, ou port non publie | `docker compose up -d` ; `docker inspect ... .NetworkSettings.Ports` (module 00) |
| `FATAL: database "X" does not exist` | le serveur repond, la base logique manque | creer la base, ou corriger `dbname` — **different** d'un probleme reseau |
| `Compilation Error ... depends on a node named 'X' which was not found` | faute de frappe dans un `ref()`, ou fichier hors de `model-paths` | verifier le nom **du fichier** (c'est lui qui nomme le modele, pas un champ interne) |
| `Model 'X' depends on 'Y' which is disabled` | `+enabled: false` quelque part dans la config hierarchique | chercher `enabled` dans `dbt_project.yml` et les `{{ config() }}` |
| `Found a cycle` | deux modeles se referencent mutuellement | casser le cycle (module 02) |
| Un test echoue mais vous ne voyez pas les lignes fautives | dbt n'affiche que le compte | `dbt test --select <test> --store-failures`, puis interroger la table de failures (module 11) |

Dans tous les cas, la sequence de diagnostic est la meme :

```bash
dbt debug                          # 1. la config et la connexion sont-elles bonnes ?
dbt parse                          # 2. les fichiers sont-ils coherents ?
dbt compile --select <modele>      # 3. que produit reellement le Jinja ?
cat target/compiled/dbt_labs/models/.../<modele>.sql   # 4. lire le SQL final
```

---

## 8. Antiseche

```bash
# Mise en route (a chaque nouveau terminal)
set -a && source .env && set +a
source .venv/bin/activate

# Cycle de dev sur un modele
dbt run  --select stg_products              # construire
dbt test --select stg_products              # tester
dbt show --select stg_products --limit 5    # regarder le resultat
dbt compile --select stg_products           # inspecter le SQL genere

# Comprendre l'impact d'un changement
dbt ls --select stg_products+ --resource-type model    # qui casse si je change ca ?
dbt build --select stg_products+                       # reconstruire tout l'aval

# Tout construire proprement
dbt deps && dbt seed && dbt build && dbt snapshot

# Diagnostiquer
dbt debug
dbt run --select fct_orders --debug
tail -100 logs/dbt.log

# Documentation et DAG visuel
dbt docs generate && dbt docs serve
```

---

Voir aussi : [reference-fichiers.md](reference-fichiers.md) (quel
fichier sert a quoi) · [glossaire.md](glossaire.md)
