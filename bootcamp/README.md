# Bootcamp dbt — du zero au niveau expert

Ce bootcamp transforme ce repo en un vrai projet dbt "d'entreprise" :
un entrepot e-commerce complet (clients, produits, commandes,
paiements, retours), construit couche par couche, avec a chaque etape
la theorie, le code reel qui tourne dans ce projet, un exercice, et
une solution commentee.

**Tout le code de reference existe deja dans ce repo et a ete
valide de bout en bout** (`dbt build` passe : `PASS=99 ERROR=0` — 80
tests de donnees, 3 unit tests, 15 modeles, seeds, snapshots,
freshness, contracts, grants). Chaque module vous explique
le "pourquoi" de ce code, vous fait pratiquer une variation, puis vous
montre + explique la solution. Vous n'apprenez pas dbt sur un jouet
academique : vous apprenez dbt en auditant/etendant un projet qui
ressemble a ce que vous trouverez en entreprise.

## A qui s'adresse ce bootcamp

A un(e) data engineer qui connait deja SQL et les bases du
data warehousing (faits/dimensions, ETL/ELT), et qui veut passer de
"je sais ecrire des modeles dbt" a "je sais concevoir, tester,
industrialiser et gouverner un projet dbt en production".

## Le projet fil rouge

Un e-commerce fictif. Donnees sources (`raw.*`, simulees dans
[`postgres/init-scripts/01_raw_schema.sql`](../postgres/init-scripts/01_raw_schema.sql)) :

- `raw.customers` — 25 clients, plusieurs pays, segment standard/vip
- `raw.products` — 15 produits, 5 categories
- `raw.orders` — 90 commandes sur les 90 derniers jours
- `raw.order_items` — 180 lignes de commande
- `raw.payments` — 90 paiements (credit_card / paypal / bank_transfer / gift_card)
- `raw.returns` — retours produits (utilise au module 12)

A la fin du bootcamp, ce raw est transforme en un entrepot complet :
staging -> intermediate -> marts (dimensions, faits, metriques),
avec tests, historisation, contrats de donnees, CI/CD et gouvernance.

```
raw.*  →  models/staging/stg_*  →  models/intermediate/int_*  →  models/marts/core/{dim_*,fct_*}
                                                                 → models/marts/returns/product_return_rates
```

## Comment suivre ce bootcamp

1. Commencez par [`00-setup`](00-setup/README.md) : sans un
   environnement qui tourne, rien d'autre n'a de sens.
2. **Puis lisez les deux fiches de reference ci-dessous.** Les
   modules expliquent *quoi* construire et *pourquoi* ; les fiches
   expliquent *comment piloter l'outil* et *comment lire ses
   sorties*. Sans elles, vous taperez des commandes sans comprendre
   ce qu'elles font ni ce qu'elles repondent.
3. Suivez les modules dans l'ordre — chacun s'appuie sur les
   precedents (le DAG du projet grandit module apres module).
4. Pour chaque module : lisez le concept, ouvrez les fichiers reels
   cites, faites l'exercice SANS regarder la solution, puis comparez.
5. Le module 12 est le projet capstone : vous y etes seul(e) face a
   un cahier des charges, comme en entreprise.

## Fiches de reference (a garder ouvertes)

| Fiche | Repond a |
|---|---|
| [reference-cli.md](reference-cli.md) | Que fait `dbt seed` / `run` / `build` / `test` ? Que veut dire `--select +modele` ? Que signifie `Found 15 models... 900 macros`, `Concurrency: 4 threads`, `[INSERT 7 in 0.05s]`, `SKIP=0` ? Ou sont parties mes tables ? Pourquoi `set -a && source .env && set +a` ? |
| [reference-fichiers.md](reference-fichiers.md) | Pourquoi un `.sql` **et** un `.yml` pour un meme modele ? Que declare chaque type de YAML ? Quelle est la priorite des configs ? Quel fichier editer pour faire X ? |

## Sommaire

| # | Module | Vous saurez... |
|---|--------|-----------------|
| 00 | [Setup](00-setup/README.md) | Monter l'environnement (Docker Postgres, venv, profils dbt via env vars) |
| 01 | [Fondamentaux](01-fondamentaux/README.md) | ELT vs ETL, `ref()`/`source()`, le DAG, les materialisations |
| 02 | [Modelisation dimensionnelle](02-modelisation-dimensionnelle/README.md) | Couches staging/intermediate/marts, modelisation en etoile (Kimball) |
| 03 | [Tests et qualite de donnees](03-tests-qualite-donnees/README.md) | Tests generiques, singuliers, `dbt_expectations`, unit tests dbt |
| 04 | [Jinja et macros avancees](04-jinja-macros-avancees/README.md) | Macros, `run_query`, packages, surcharge de macros dbt |
| 05 | [Incremental et performance](05-incremental-performance/README.md) | Materialisations incrementales, strategies, index, performance |
| 06 | [Snapshots et SCD](06-snapshots-scd/README.md) | Slowly Changing Dimensions, snapshots dbt |
| 07 | [Sources, freshness, exposures, contracts](07-sources-freshness-exposures-contracts/README.md) | Fraicheur des sources, exposures, contrats de donnees, grants |
| 08 | [Semantic layer / MetricFlow](08-semantic-layer-metricflow/README.md) | Semantic models, metrics, dbt Semantic Layer |
| 09 | [Orchestration et CI/CD](09-orchestration-ci-cd/README.md) | GitHub Actions, slim CI, selecteurs, orchestrateurs externes |
| 10 | [Gouvernance et multi-projets](10-gouvernance-multi-projets/README.md) | Groups, access modifiers, dbt Mesh, packages prives |
| 11 | [Observabilite et performance avancee](11-observabilite-performance/README.md) | Artifacts dbt, logging, EXPLAIN ANALYZE, monitoring |
| 12 | [Projet capstone](12-projet-capstone/README.md) | Livrer un domaine complet, seul(e), de A a Z |

Complements : [reference-cli.md](reference-cli.md) ·
[reference-fichiers.md](reference-fichiers.md) ·
[glossaire.md](glossaire.md) · [ressources.md](ressources.md)

## Conventions utilisees dans ce bootcamp

- Tous les chemins de fichiers sont relatifs a la racine du repo.
- `$` en debut de ligne = commande a taper dans votre terminal, a la
  racine du projet, apres avoir charge les variables d'environnement :
  ```bash
  set -a && source .env && set +a
  ```
- Les blocs "**Exercice**" sont a faire vous-meme. Les blocs
  "**Solution**" contiennent la reponse ET l'explication du
  raisonnement — pas juste le code.
