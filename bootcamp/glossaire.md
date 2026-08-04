# Glossaire

> Pour les commandes et la lecture des sorties dbt, voir
> [reference-cli.md](reference-cli.md). Pour le role de chaque type de
> fichier, voir [reference-fichiers.md](reference-fichiers.md).

## Vocabulaire de l'outil

**Adapter** — Le traducteur entre dbt et le dialecte SQL de votre
entrepot (`dbt-postgres`, `dbt-duckdb`, `dbt-snowflake`...). Il decide
de ce qui est possible : `merge` existe sur Snowflake, pas sur
Postgres. Affiche a chaque commande (`Registered adapter: postgres=1.9.1`).

**Profile / target** — Un `profile` (dans `~/.dbt/profiles.yml`)
regroupe plusieurs `targets` (`dev`, `ci`, `prod`) : chacun est un jeu
de coordonnees de connexion. `target='dev'` s'affiche a chaque run —
c'est votre garde-fou avant une commande destructive.

**Thread** — Nombre de noeuds que dbt execute en parallele quand le
DAG le permet (`threads:` dans `profiles.yml`). Principal levier de
vitesse gratuit.

**Seed** — Un CSV versionne dans git, charge tel quel en table par
`dbt seed`. Reserve aux referentiels **petits**, **stables** et
**sans proprietaire ailleurs** (pays, devises, mapping de codes). Un
export de production n'est pas un seed.

**`dbt build`** — seed + run + test + snapshot **entrelaces dans
l'ordre du DAG** : chaque modele est teste avant que ses enfants ne
soient construits. A distinguer de `dbt run && dbt test`, qui
construit tout d'abord et teste apres — laissant un modele fautif
contaminer tout l'aval. En CI/prod, toujours `dbt build`.

**Selection (`--select`)** — Grammaire commune a `run`, `test`,
`build`, `ls`, `compile`. Operateurs de graphe (`+modele`, `modele+`,
`@modele`, `2+modele`), methodes (`path:`, `tag:`, `state:`,
`test_type:`, `source:`, `exposure:`, `config.materialized:`), union
(espace) vs intersection (virgule). Voir
[reference-cli.md](reference-cli.md).

**`SKIP`** — Dans le bilan `PASS/WARN/ERROR/SKIP/NO-OP` : un noeud non
execute **parce qu'un parent a echoue**. Ce n'est pas un probleme en
soi — remontez au premier `ERROR`.

**Resolution de schema** — Le schema reel d'une table = combinaison de
`target.schema` (depuis `profiles.yml`/`.env`), du `+schema:` du
dossier (`dbt_project.yml`), et de la macro `generate_schema_name`.
D'ou `CIC_DWH_marts` en dev et `marts` en prod. Voir
[module 00](00-setup/README.md).

## Vocabulaire de la modelisation

**ELT / ETL** — Extract-Load-Transform vs Extract-Transform-Load. dbt
ne fait que le T : il transforme des donnees deja chargees dans
l'entrepot. Voir [module 01](01-fondamentaux/README.md).

**Source** — Une table brute externe a dbt, declaree dans un YAML
(`source()`), jamais nommee en dur dans le SQL. Voir [module 01](01-fondamentaux/README.md).

**`ref()`** — Fonction Jinja qui resout le nom reel (schema/base
inclus) d'un modele dbt, et construit le DAG en analysant tous les
appels. Voir [module 01](01-fondamentaux/README.md).

**DAG** — Graphe Acyclique Dirige : l'ordre d'execution des modeles,
deduit automatiquement des `ref()`/`source()`. `dbt ls --select
+modele` le liste.

**Materialisation** — Comment un modele est physiquement construit :
`view`, `table`, `incremental`, `ephemeral`. Voir [module 01](01-fondamentaux/README.md).

**Staging / Intermediate / Marts** — Les trois couches conventionnelles
d'un projet dbt : renommage pur, logique metier non exposee, interface
finale consommee. Voir [module 02](02-modelisation-dimensionnelle/README.md).

**Kimball / modelisation en etoile** — Methode de modelisation
dimensionnelle : tables de faits (`fct_*`, mesures numeriques) +
dimensions (`dim_*`, attributs descriptifs). Voir [module 02](02-modelisation-dimensionnelle/README.md).

**Grain** — La granularite d'une table : ce qu'une seule ligne
represente ("1 ligne = 1 commande"). A definir AVANT d'ecrire le SQL.

**Test generique** — Une macro `{% test nom(model, column_name) %}`
reutilisable sur n'importe quelle colonne via YAML. Voir [module 03](03-tests-qualite-donnees/README.md).

**Test singulier** — Un fichier `.sql` dans `tests/`, une regle
metier specifique, non reutilisable telle quelle.

**Unit test** — Test dbt (>= 1.8) qui verifie la LOGIQUE d'un modele
avec des donnees d'entree fictives, sans toucher l'entrepot. Voir
[module 03](03-tests-qualite-donnees/README.md).

**`severity`** — `error` (bloque le build, defaut) ou `warn` (log
mais continue). Voir [module 03](03-tests-qualite-donnees/README.md).

**`store_failures`** — Materialise les lignes en echec d'un test dans
une table interrogeable apres coup. Voir [module 11](11-observabilite-performance/README.md).

**Macro** — Fonction Jinja reutilisable (`{% macro %}`), peut generer
du SQL, appeler d'autres macros, interroger l'entrepot a la
compilation (`run_query`). Voir [module 04](04-jinja-macros-avancees/README.md).

**`run_query`** — Execute du SQL DURANT la compilation (pas au run)
et retourne le resultat exploitable en Jinja. Voir [module 04](04-jinja-macros-avancees/README.md).

**`is_incremental()`** — Fonction Jinja vraie seulement lors d'un run
incrementel sur une table deja existante (pas au premier run, pas
avec `--full-refresh`). Voir [module 05](05-incremental-performance/README.md).

**High-water mark** — Pattern incrementale : ne retraiter que ce qui
est plus recent que le maximum deja charge. Voir [module 05](05-incremental-performance/README.md).

**`unique_key`** — Cle utilisee par une materialisation incrementale
pour identifier "la meme ligne" entre deux runs (mise a jour au lieu
de doublon). Voir [module 05](05-incremental-performance/README.md).

**SCD (Slowly Changing Dimension)** — Pattern de gestion de
l'historique d'une dimension qui change. Le Type 2 (nouvelle version
+ periode de validite) est celui implemente par les snapshots dbt.
Voir [module 06](06-snapshots-scd/README.md).

**Snapshot** — Objet dbt qui historise l'etat d'une source/d'un
modele dans le temps (`dbt_valid_from`/`dbt_valid_to`). Voir [module 06](06-snapshots-scd/README.md).

**Source freshness** — Verification que les donnees sources arrivent
a temps, basee sur une colonne d'horodatage TECHNIQUE d'extraction
(pas metier). Voir [module 07](07-sources-freshness-exposures-contracts/README.md).

**Exposure** — Declaration YAML documentant qu'un outil externe (BI,
rapport) depend de certains modeles dbt. Voir [module 07](07-sources-freshness-exposures-contracts/README.md).

**Contract (contrat de donnees)** — Configuration qui fige le schema
d'un modele (types, contraintes) et fait echouer la compilation en
cas d'ecart. Voir [module 07](07-sources-freshness-exposures-contracts/README.md).

**Grants** — Permissions SQL (`GRANT`/`REVOKE`) gerees comme code
depuis la config d'un modele dbt. Voir [module 07](07-sources-freshness-exposures-contracts/README.md).

**Semantic model / Metric / MetricFlow** — Definition centralisee
d'entites/dimensions/mesures (semantic model) et des KPIs qui en
decoulent (metrics), interrogeable par des outils BI via le dbt
Semantic Layer. Voir [module 08](08-semantic-layer-metricflow/README.md).

**Time spine** — Table calendaire de reference obligatoire des qu'un
projet definit des metrics. Voir [module 08](08-semantic-layer-metricflow/README.md).

**Slim CI / `state:modified+`** — Ne construire/tester que les
modeles modifies (et leurs enfants) par rapport a un manifest de
reference, pour accelerer la CI. Voir [module 09](09-orchestration-ci-cd/README.md).

**Selecteur (`selectors.yml`)** — Definition YAML nommee et
reutilisable d'un `--select` complexe. Voir [module 09](09-orchestration-ci-cd/README.md).

**Group** — Regroupement de modeles par domaine/equipe responsable,
avec un `owner`. Voir [module 10](10-gouvernance-multi-projets/README.md).

**Access modifier** — `private` (memes groupe seulement), `protected`
(tout le projet, defaut), `public` (autres projets dbt aussi, dbt
Mesh). Voir [module 10](10-gouvernance-multi-projets/README.md).

**dbt Mesh** — Architecture multi-projets dbt independants qui se
referencent entre eux via des modeles `public`, comme des packages.
Voir [module 10](10-gouvernance-multi-projets/README.md).

**Artifacts (`manifest.json`, `run_results.json`, `catalog.json`)** —
Fichiers JSON generes dans `target/`, source de verite machine-readable
du projet et de ses executions. Voir [module 11](11-observabilite-performance/README.md).
