# Module 10 — Gouvernance et architecture multi-projets

## Objectifs

- Organiser un projet en `groups` (domaines/equipes).
- Comprendre et utiliser les `access modifiers` (`private`,
  `protected`, `public`).
- Situer dbt Mesh (multi-projets) et les packages prives.
- Choisir entre monorepo et polyrepo en connaissance de cause.

## Groups : decouper un projet en domaines

[`models/groups.yml`](../../models/groups.yml) :

```yaml
groups:
  - name: core
    owner: { name: "Data Platform Team", email: data-platform@example.com }
  - name: returns
    owner: { name: "Customer Experience Team", email: cx-analytics@example.com }
```

Un `group` associe des modeles a une equipe responsable (`owner`).
Dans [`dbt_project.yml`](../../dbt_project.yml) :

```yaml
models:
  dbt_labs:
    +group: core          # tout le projet est "core" par defaut
    marts:
      returns:
        +group: returns   # sauf models/marts/returns/, qui appartient a "returns"
```

`product_return_rates` (groupe `returns`, cree pour le domaine
retours produits, module 12) reste dans le MEME projet dbt physique
que `dim_customers` (groupe `core`) — les groupes ne decoupent pas
des repos differents, ils decoupent la RESPONSABILITE a l'interieur
d'un seul projet.

## Access modifiers : qui a le droit de referencer quoi

Trois niveaux, du plus au moins permissif :

| Access | Referencable par |
|---|---|
| `public` | N'importe quel modele, meme dans un AUTRE projet dbt (dbt Mesh) |
| `protected` | N'importe quel modele DANS ce projet, quel que soit son groupe |
| `private` | Seulement les modeles du MEME groupe |

**`protected` est le defaut** : un modele sans `access:` declare est
`protected`. Retenez-le, parce que la consequence est contre-intuitive
— un modele que vous n'avez pas pense a marquer `public` **n'est pas
referençable depuis un autre projet dbt**. Sur un monorepo (ce
projet), la difference est invisible ; le jour d'un split en dbt Mesh,
c'est ce qui determine votre interface publique.

`private` est le seul des trois qui exige un `group` : sans groupe
declare, "le meme groupe" ne veut rien dire et dbt refuse la config.

Dans ce projet : `dim_customers`, `dim_products`, `dim_dates`,
`fct_orders`, `fct_order_items` et `product_return_rates` sont
`access: public` (l'interface officielle du warehouse — voir
[`_core__models.yml`](../../models/marts/core/_core__models.yml) et
[`_returns__models.yml`](../../models/marts/returns/_returns__models.yml)).
`int_order_amounts` et `int_payments_pivoted` sont `access: private`
(voir [`_intermediate__models.yml`](../../models/intermediate/_intermediate__models.yml)) —
personne HORS du groupe `core` ne doit pouvoir batir une dependance
dessus, precisement parce que ce sont des details d'implementation
susceptibles de changer sans préavis.

## Demonstration reelle de l'application stricte de la regle

En construisant ce module, on a teste volontairement : passer
`stg_returns` (groupe `core`, par heritage) en `access: private`,
alors que `product_return_rates` (groupe `returns`) le reference.

```yaml
# models/staging/_staging__models.yml (test, ensuite annule)
  - name: stg_returns
    access: private
```

```bash
dbt parse
```

```
Parsing Error
  Node model.dbt_labs.product_return_rates attempted to reference
  node model.dbt_labs.stg_returns, which is not allowed because the
  referenced node is private to the 'core' group.
```

**dbt bloque a la compilation**, pas a l'execution — vous le
detectez en 2 secondes en local, pas apres 20 minutes de `dbt run` en
CI. C'est exactement le genre de garde-fou qui, en entreprise, evite
qu'une equipe A batisse silencieusement une dependance critique sur
un detail d'implementation interne de l'equipe B, qui casse tout des
que B refactore sans prevenir (parce que B ne savait meme pas que A
dependait de ce modele).

## Pourquoi `int_*` est private mais `stg_*` reste `protected`

Vous auriez pu vous attendre a ce que TOUT le staging soit `private`.
Choix assume ici : le staging (renommage/cast pur, module 02) est un
socle suffisamment stable et generique pour etre reference par
d'autres domaines du MEME projet sans risque — c'est la couche
intermediate (agregations/pivots, logique metier volatile) qui merite
d'etre strictement encapsulee. Regle pratique : **`private` la ou
l'implementation est un detail susceptible de changer ; `protected`
la ou c'est un socle stable ; `public` uniquement l'interface
officiellement documentee et versionnee (contracts, module 07).**

## dbt Mesh : quand un seul projet ne suffit plus

Passe un certain nombre d'equipes/modeles, un seul projet dbt devient
un goulot d'etranglement (un seul `dbt_project.yml`, une seule CI, un
DAG immense a `dbt compile` a chaque changement). **dbt Mesh**
decoupe en PLUSIEURS projets dbt independants (equipe Finance, equipe
Marketing, plateforme Data...), chacun avec son propre repo/CI/deploiement,
qui se referencent entre eux comme des packages :

```yaml
# packages.yml du projet "marketing"
packages:
  - package: votre-org/core_warehouse
    version: [">=2.0.0", "<3.0.0"]
```

```sql
-- dans le projet "marketing"
select * from {{ ref('core_warehouse', 'dim_customers') }}
```

Seuls les modeles `access: public` du projet `core_warehouse` sont
referençables ainsi — exactement le meme mecanisme d'access modifiers
que dans CE bootcamp (un seul projet), mais applique ENTRE projets.
C'est pourquoi il est utile de pratiquer la discipline `public` /
`protected` / `private` des le debut, meme sur un petit projet
mono-repo : le jour ou vous splittez en dbt Mesh, l'interface publique
est deja correctement delimitee, zero effort de migration.

## Packages prives (avant/sans dbt Mesh)

Meme sans Mesh complet, un projet dbt peut consommer un package prive
git (macros/modeles partages entre projets d'une meme organisation) :

```yaml
packages:
  - git: "git@github.com:votre-org/dbt_macros_communes.git"
    revision: v1.4.0
```

Usage typique : mutualiser des macros transverses (formats de dates
maison, conventions de nommage de schema comme
`generate_schema_name`, module 04) sans dupliquer le code entre
projets.

## Monorepo vs polyrepo : le compromis reel

| | Monorepo (ce projet) | Polyrepo (dbt Mesh) |
|---|---|---|
| Vitesse de demarrage | Rapide, zero coordination inter-repo | Overhead initial (packages, versioning, CI par projet) |
| Isolation des pannes | Un bug dans un domaine peut bloquer TOUT `dbt compile` | Un projet casse n'affecte pas les autres |
| Gouvernance | Groups/access modifiers (ce module) suffisent | Necessaire au-dela d'~5-10 equipes |
| CI | Un seul pipeline a maintenir | Un pipeline par projet, plus complexe |

Ne migrez vers un dbt Mesh multi-projets QUE quand la douleur du
monorepo est reelle et mesuree (temps de `dbt compile`, conflits de
deploiement entre equipes) — pas par anticipation. Ce bootcamp reste
volontairement en monorepo avec groups/access modifiers : c'est
l'etape qui precede naturellement un eventuel passage a dbt Mesh, pas
un raccourci.

## Exercice

Creez un troisieme groupe `marketing`, proprietaire d'un nouveau mart
`models/marts/marketing/customer_segments_summary.sql` (grain =
1 ligne par `customer_segment` x `country_code`, avec le nombre de
clients et la LTV moyenne), qui consomme `dim_customers` (public,
groupe `core`).

### Solution

```yaml
# models/groups.yml, ajout
  - name: marketing
    owner: { name: "Marketing Analytics", email: marketing-analytics@example.com }
```

```yaml
# dbt_project.yml, sous models.dbt_labs.marts
      marketing:
        +group: marketing
```

```sql
-- models/marts/marketing/customer_segments_summary.sql
select
    customer_segment,
    country_code,
    count(*) as customer_count,
    avg(lifetime_value_cents) as avg_lifetime_value_cents
from {{ ref('dim_customers') }}
group by customer_segment, country_code
```

Ca compile sans probleme des le depart : `dim_customers` est deja
`access: public`, donc referençable depuis n'importe quel groupe,
`marketing` y compris — c'est tout l'interet d'avoir marque l'
interface du domaine `core` comme publique des le module 07/10
initial plutot que de le decouvrir en marchant dessus.

## Suite

→ [Module 11 — Observabilite et performance avancee](../11-observabilite-performance/README.md)
