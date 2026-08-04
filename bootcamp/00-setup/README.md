# Module 00 — Mettre en place l'environnement

## Objectifs

- Faire tourner un Postgres local via Docker, pre-charge avec des
  donnees "source" realistes.
- Installer dbt dans un environnement Python isole.
- Configurer `profiles.yml` **sans jamais committer de secret**.
- Executer `dbt debug` avec succes.

## Pourquoi Postgres en local et pas un cloud warehouse ?

Ce bootcamp doit rester gratuit et rejouable a l'infini. Postgres via
Docker donne un warehouse SQL reel (pas un mock) sur lequel `dbt run`,
`dbt test`, les snapshots, les contracts, les grants... se comportent
comme sur Snowflake/BigQuery/Databricks. Les concepts sont
100% transferables ; seule la syntaxe SQL specifique a l'adapter
changerait en changeant de warehouse.

## 1. Prerequis

- Docker + Docker Compose (`docker compose version`)
- Python 3.10+ 
- Un terminal a la racine de ce repo

## 2. Demarrer Postgres

Le fichier [`compose.yml`](../../compose.yml) definit un service
`dbt_labs_postgres`. Regardez-le : c'est un Postgres 15 standard, avec
un point important —

```yaml
volumes:
    - ./postgres/init-scripts/:/docker-entrypoint-initdb.d/
    - dbt-labs-pg-data:/var/lib/postgresql/data
```

Tout fichier `.sql` dans `postgres/init-scripts/` est execute
automatiquement **une seule fois**, au tout premier demarrage (volume
vide). C'est [`01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql)
qui cree le schema `raw` et le peuple avec le jeu de donnees
e-commerce du bootcamp — c'est votre "systeme source" simule.

```bash
docker compose up -d
docker compose logs -f dbt_labs_postgres   # Ctrl+C quand "ready to accept connections"
```

### Piege reel rencontre en construisant ce bootcamp

La toute premiere version de `compose.yml` de ce repo declarait :

```yaml
networks:
  rcd_net:
    internal: true
    name: dbt_labs_net
```

`internal: true` isole completement le reseau Docker — y compris le
port publie `5432:5432`. Resultat : Postgres demarrait, `pg_isready`
passait **depuis l'interieur du conteneur**, mais `dbt debug` depuis
l'hote echouait avec `Connection refused`, alors que tout semblait
correctement configure. Le correctif : retirer `internal: true`
(voir le commentaire dans `compose.yml`). Retenez le reflexe de
debug : `docker inspect <container> --format '{{json .NetworkSettings.Ports}}'`
doit montrer un `HostIp`/`HostPort` non vide. Si c'est `[]`, le port
n'est pas vraiment publie, quoi que dise `docker ps`.

## 3. Environnement Python + dbt

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install dbt-postgres   # installe aussi dbt-core en dependance
dbt --version
```

Ce repo a deja un `.venv/` avec `dbt-core==1.10.13` et
`dbt-postgres==1.9.1` installes — si vous travaillez dans ce repo
directement, `source .venv/bin/activate` suffit.

## 4. Secrets : `.env` + `profiles.yml` via `env_var()`

Deux fichiers a ne **jamais** committer (deja dans `.gitignore`) :
`.env` (racine du projet) et `~/.dbt/profiles.yml` (hors du repo, par
construction).

`.env` (creez-le a partir de vos propres identifiants) :

```
POSTGRES_HOST=127.0.0.1
POSTGRES_PORT=5432
POSTGRES_DB=dbt_labs
POSTGRES_SCHEMA=dbt_jeff       # <- VOTRE prenom, pas celui-ci
POSTGRES_USER=admin_dbt_labs
POSTGRES_PASSWORD=...
```

**`POSTGRES_SCHEMA` merite une explication**, parce que c'est la
variable la plus mal comprise du lot. Ce n'est **pas** le nom de
votre entrepot : c'est le nom de **votre bac a sable personnel**.
Convention dbt Labs : `dbt_<prenom>`.

Toutes vos tables de dev en heriteront comme prefixe
(`dbt_jeff_staging`, `dbt_jeff_marts`...), ce qui garantit trois
choses :

1. deux developpeurs sur la meme base ne s'ecrasent jamais ;
2. votre `dbt run` ne peut pas toucher les tables de production ;
3. vous pouvez jeter tout votre travail d'un
   `drop schema dbt_jeff_marts cascade` sans rien risquer.

Mettre ici un nom d'entrepot (`CIC_DWH`, `ANALYTICS`...) compile
parfaitement, mais brouille cette intention : on ne sait plus, en
lisant un nom de schema, si on regarde un espace de travail jetable
ou une ressource partagee.

`~/.dbt/profiles.yml` (copiez [`profiles.yml.example`](../../profiles.yml.example)) —
regardez bien : **aucun mot de passe en clair**, tout passe par
`env_var()` :

```yaml
dbt_labs:
  target: dev
  outputs:
    dev:
      type: postgres
      host: "{{ env_var('POSTGRES_HOST', 'localhost') }}"
      port: "{{ env_var('POSTGRES_PORT', '5432') | as_number }}"
      user: "{{ env_var('POSTGRES_USER') }}"
      password: "{{ env_var('POSTGRES_PASSWORD') }}"
      dbname: "{{ env_var('POSTGRES_DB') }}"
      schema: "{{ env_var('POSTGRES_SCHEMA') }}"
      threads: 4
```

`env_var()` sans valeur par defaut **fait planter dbt** si la
variable n'existe pas — c'est volontaire : mieux vaut un echec net a
la compilation qu'un run silencieux avec un mauvais mot de passe.

```
Parsing Error
  Env var required but not provided: 'POSTGRES_SCHEMA'
```

**Remarquez lesquelles ont un defaut et lesquelles n'en ont pas.**
Ce n'est pas arbitraire :

| Variable | Defaut | Pourquoi |
|---|---|---|
| `POSTGRES_HOST` | `localhost` | se tromper est visible immediatement (connexion refusee) |
| `POSTGRES_PORT` | `5432` | idem |
| `POSTGRES_USER` / `PASSWORD` / `DB` | **aucun** | un defaut ferait tenter une connexion avec de mauvais identifiants |
| `POSTGRES_SCHEMA` | **aucun** | **c'est le cas le plus subtil** — voir ci-dessous |

Un defaut du type `env_var('POSTGRES_SCHEMA', 'dbt_dev')` parait
pratique, et c'est un piege : si deux developpeurs oublient de
definir la variable, ils atterrissent **tous les deux** dans
`dbt_dev_*` et s'ecrasent mutuellement, sans la moindre erreur. Le
garde-fou du schema par developpeur disparait exactement au moment ou
quelqu'un est distrait — c'est-a-dire quand on en a le plus besoin.

Regle generale : **mettez un defaut quand se tromper est bruyant,
jamais quand se tromper est silencieux.**

Avant chaque commande dbt, chargez `.env` dans votre shell :

```bash
set -a && source .env && set +a
```

Decomposons, parce que cette ligne va revenir a chaque module et
qu'une seule des trois parties est evidente :

| Element | Role |
|---|---|
| `source .env` | execute le fichier dans le **shell courant** : chaque `CLE=valeur` devient une variable de shell |
| `set -a` | mode "allexport" : toute variable definie ensuite est automatiquement **exportee** |
| `set +a` | desactive ce mode (on ne veut pas exporter tout ce qu'on tapera ensuite) |

Le point qui compte est la difference **variable de shell** vs
**variable d'environnement** :

```bash
POSTGRES_USER=admin          # variable de SHELL : visible par vous seul
export POSTGRES_USER=admin   # variable d'ENVIRONNEMENT : heritee par les
                             # processus enfants
```

`dbt` est un **processus enfant** de votre shell : il ne recoit que
l'environnement exporte. `source .env` sans `set -a` definit bien les
variables, mais dbt ne les voit pas, et `env_var('POSTGRES_USER')`
plante avec `Env var required but not provided`.

Trois consequences pratiques :

1. **La portee est le terminal.** Nouvel onglet = nouveau shell = il
   faut refaire la commande. Ce n'est pas persistant, et c'est voulu.
2. **Verifiez au lieu de deviner** : `echo $POSTGRES_USER`. Vide =
   pas charge.
3. **Alternative confortable** : [`direnv`](https://direnv.net/)
   charge/decharge le `.env` automatiquement en entrant/sortant du
   dossier. En revanche, ne mettez pas `source .env` dans votre
   `~/.zshrc` : vous auriez des identifiants de base de donnees dans
   tous vos shells en permanence.

## 5. Verifier

```bash
set -a && source .env && set +a
dbt deps      # installe dbt_utils, dbt_expectations, codegen (packages.yml)
dbt debug     # doit finir par "All checks passed!"
```

## 6. Ou vont atterrir vos tables ? (a lire avant le premier run)

Vous avez mis `POSTGRES_SCHEMA=dbt_jeff` dans `.env`. Pourtant, au
premier `dbt seed`, dbt annonce :

```
1 of 2 OK loaded seed file dbt_jeff_seeds.countries [INSERT 7 in 0.05s]
                                ^^^^^^^^^^^^^^^^^ d'ou sort ce suffixe ?
```

Trois ingredients se combinent :

```
1. .env                POSTGRES_SCHEMA=dbt_jeff
2. profiles.yml        schema: "{{ env_var('POSTGRES_SCHEMA') }}"
                       -> target.schema = "dbt_jeff"    (schema de BASE)
3. dbt_project.yml     seeds:   +schema: seeds         (schema CUSTOM)
                       staging: +schema: staging
                       marts:   +schema: marts
4. macros/generate_schema_name.sql   combine 2 et 3

   -> en dev  : dbt_jeff_seeds, dbt_jeff_staging, dbt_jeff_marts
   -> en prod : seeds, staging, marts   (sans prefixe)
```

La logique de
[`macros/generate_schema_name.sql`](../../macros/generate_schema_name.sql)
(le snippet standard recommande par dbt Labs, detaille au
[module 04](../04-jinja-macros-avancees/README.md)) : en production,
des noms de schemas propres ; partout ailleurs, un prefixe par
developpeur pour que deux personnes puissent travailler sur la meme
base sans s'ecraser.

### "Je veux `seeds` et pas `dbt_jeff_seeds`" — la mauvaise question

C'est la reaction de tout le monde en decouvrant le prefixe. Trois
precisions avant de toucher quoi que ce soit :

**1. Retirer `POSTGRES_SCHEMA` ne donne pas `seeds`.** Le prefixe
vient de la macro, pas de la variable. Sans variable, dbt echoue
(pas de valeur par defaut, section 4) ; avec un defaut, vous
obtiendriez `dbt_dev_seeds` — toujours prefixe.

**2. Seul `target=prod` produit les noms nus**, et c'est voulu :

| Configuration | Schema obtenu |
|---|---|
| `POSTGRES_SCHEMA=dbt_jeff`, target `dev` | `dbt_jeff_seeds` |
| `--target prod` | `seeds` |

**3. Forcer les noms nus en local vous coute plus que ca ne rapporte.**

| Methode | Ce que vous perdez |
|---|---|
| `dbt run --target prod` en local | La ligne `target='dev'` affichee a chaque run est votre dernier rempart avant un `--full-refresh` destructeur |
| Modifier la macro pour ne plus prefixer en dev | Deux developpeurs sur la meme base s'ecrasent, sans erreur |
| Supprimer les `+schema:` de `dbt_project.yml` | Tout atterrit a plat dans un seul schema : plus de separation staging/marts, et votre dev ne ressemble plus a votre prod |

Le prefixe n'est pas une verrue de configuration : c'est le
mecanisme qui rend votre environnement de dev **jetable**. Gardez-le,
et choisissez simplement une valeur qui dit ce qu'elle est
(`dbt_<prenom>`).

Verifiez a tout moment ce qui existe reellement :

```bash
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" dbt_labs_postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  -c "select table_schema, count(*) from information_schema.tables
      where table_schema not in ('pg_catalog','information_schema')
      group by 1 order by 1;"
```

Apres un `dbt build` complet, vous devez voir 4 schemas : `raw`
(votre source simulee), `dbt_jeff_seeds`, `dbt_jeff_staging`,
`dbt_jeff_marts`.

**Reflexe general** : ne cherchez jamais vos tables au jugé. Le nom
exact `schema.table` est ecrit dans la sortie de dbt apres chaque
`START`/`OK`, et dans le SQL compile de `target/compiled/`.

## Exercice

1. Ajoutez un target `ci` a votre `profiles.yml` local qui pointe
   vers une base `dbt_labs_ci` (n'a pas besoin d'exister reellement,
   juste de compiler).
2. Lancez `dbt debug --target ci` : que se passe-t-il si `dbt_labs_ci`
   n'existe pas encore dans Postgres ? Quelle est la difference entre
   une erreur de **connexion** et une erreur de **base manquante** ?

### Solution

Un target `ci` supplementaire dans `profiles.yml` :

```yaml
    ci:
      type: postgres
      host: "{{ env_var('POSTGRES_HOST', 'localhost') }}"
      port: "{{ env_var('POSTGRES_PORT', '5432') | as_number }}"
      user: "{{ env_var('POSTGRES_USER') }}"
      password: "{{ env_var('POSTGRES_PASSWORD') }}"
      dbname: dbt_labs_ci
      schema: ci
      threads: 4
```

`dbt debug --target ci` va reussir a **ouvrir une connexion TCP**
vers Postgres (le serveur existe), mais Postgres refusera la
connexion au niveau applicatif avec une erreur du type
`FATAL: database "dbt_labs_ci" does not exist`. C'est une distinction
importante a savoir diagnostiquer : "le reseau/port est OK mais la
ressource logique n'existe pas" est une classe d'erreur totalement
differente de "je n'atteins meme pas le serveur" (comme le piege
`internal: true` plus haut). Le module 09 (CI/CD) reutilise ce genre
de target dedie pour isoler chaque run de CI dans son propre schema.

## Suite

Avant d'enchainer, lisez [reference-cli.md](../reference-cli.md) : ce
sont les commandes dbt, la syntaxe `--select` et surtout **comment
lire ce que dbt vous repond**. Les modules suivants supposent ces
bases acquises et ne re-expliquent pas chaque commande.

→ [Module 01 — Fondamentaux dbt](../01-fondamentaux/README.md)
