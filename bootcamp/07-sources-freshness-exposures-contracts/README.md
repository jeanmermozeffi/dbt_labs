# Module 07 — Sources, freshness, exposures, contracts, grants

## Objectifs

- Configurer et interpreter la fraicheur des sources (`dbt source freshness`).
- Declarer des exposures pour suivre l'impact d'un changement sur la BI.
- Appliquer un contrat de donnees (`contract: enforced`) sur un mart critique.
- Gerer des permissions SQL (`grants`) depuis dbt.

## Source freshness : surveiller le pipeline, pas les donnees

`dbt source freshness` repond a **une seule question** : *"mon
pipeline d'ingestion tourne-t-il encore ?"* Il compare l'age de la
ligne la plus recente d'une source a deux seuils :

```yaml
# models/staging/_staging__sources.yml
- name: orders
  loaded_at_field: _loaded_at        # <- horodatage TECHNIQUE d'extraction
  freshness:
    warn_after:  { count: 36, period: hour }
    error_after: { count: 72, period: hour }
```

Concretement, dbt execute `select max(_loaded_at) from raw.orders` et
compare a `now()` :

| Age du `max(loaded_at_field)` | Statut | Effet |
|---|---|---|
| < 36 h | `PASS` | rien |
| 36 h – 72 h | `WARN` | signale, code de sortie 0 |
| > 72 h | `ERROR` | **code de sortie non nul** — fait echouer un job CI |

```bash
dbt source freshness
```

```
1 of 6 PASS freshness of raw.customers ......... [PASS in 0.04s]
...
Done.
```

Cette commande est **independante** de `dbt run`/`dbt test` : elle
n'est pas incluse dans `dbt build`. En production, on la planifie
separement et **avant** le run (inutile de transformer des donnees
dont on sait deja qu'elles n'ont pas ete rafraichies).

## Piege reel : freshness sur la mauvaise colonne

En construisant ce projet, `raw.customers` utilisait `updated_at`
(un horodatage METIER — la derniere fois que ce client a change) comme
`loaded_at_field`. Resultat : `dbt source freshness` echouait en
PERMANENCE sur les clients inscrits il y a plusieurs mois et jamais
modifies depuis — alors que le pipeline d'ingestion, lui, tournait
parfaitement. Un `ERROR STALE` en continu que personne ne peut
distinguer d'une vraie panne = une alerte que tout le monde finit par
ignorer.

Le correctif dans
[`postgres/init-scripts/01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql) :
ajout d'une colonne technique dediee, `_loaded_at timestamp not null
default now()`, distincte de `updated_at`. Puis dans
[`_staging__sources.yml`](../../models/staging/_staging__sources.yml) :

```yaml
- name: customers
  # _loaded_at = horodatage technique d'EXTRACTION.
  # updated_at = horodatage METIER, sans lien avec la sante du pipeline.
  loaded_at_field: _loaded_at
```

**La regle generale** : `loaded_at_field` doit toujours repondre a
"quand ce pipeline a-t-il tourne pour la derniere fois ?", jamais a
"quand cet enregistrement a-t-il change pour la derniere fois ?". Ce
sont deux questions differentes qui ont souvent, a tort, la meme
colonne dans des projets mal concus.

### La regle n'avait ete appliquee qu'a moitie dans ce repo

Ce projet documentait la lecon ci-dessus... en ne la respectant que
sur 2 sources sur 6. Etat constate avant correction :

| Source | `loaded_at_field` | Nature |
|---|---|---|
| `customers` | `_loaded_at` | technique — correct |
| `products` | `_loaded_at` | technique — correct |
| `orders` | `updated_at` | **metier — l'anti-pattern decrit ci-dessus** |
| `payments` | `paid_at` | **metier** |
| `returns` | `returned_at` | **metier** |
| `order_items` | *(aucun)* | pas de freshness du tout |

Consequence mesurable : `dbt source freshness` renvoyait
**4 `ERROR` sur 6 sources**, en permanence, sans qu'aucun pipeline ne
soit en panne. Exactement l'alerte-qui-crie-au-loup que la section
precedente decrit.

La correction (appliquee) a consiste a ajouter `_loaded_at` aux
quatre tables qui en manquaient dans
[`postgres/init-scripts/01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql),
puis a pointer les six sources dessus. Resultat :

```
Done.   # 6 of 6 PASS
```

**La lecon meta** : une regle enoncee dans une doc ne vaut rien tant
qu'elle n'est pas verifiee mecaniquement. Ici, la verification tient
en une commande — encore fallait-il la lancer.

### Le piege du jeu de donnees de demonstration

Attention en refaisant ce module : `error_after: 72 hours` compte a
partir de **maintenant**. Le schema `raw` est peuple **une seule
fois**, au premier demarrage du conteneur (volume vide). Si votre
Postgres tourne depuis plus de 3 jours, `dbt source freshness`
echouera sur tout — non pas parce que vous avez fait une erreur, mais
parce que la donnee de demo a reellement vieilli.

Pour repartir d'un etat frais sans detruire le volume :

```bash
set -a && source .env && set +a
docker exec -e PGPASSWORD="$POSTGRES_PASSWORD" dbt_labs_postgres \
  psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "
    update raw.customers   set _loaded_at = now();
    update raw.products    set _loaded_at = now();
    update raw.orders      set _loaded_at = now();
    update raw.order_items set _loaded_at = now();
    update raw.payments    set _loaded_at = now();
    update raw.returns     set _loaded_at = now();"
dbt source freshness   # 6 of 6 PASS
```

En production, ce probleme n'existe pas : `_loaded_at` est mis a jour
par l'outil d'ingestion a chaque chargement. C'est un artefact d'un
jeu de donnees fige — mais savoir distinguer "ma source est vraiment
en retard" de "mon environnement de demo a vieilli" fait partie du
metier.

## Exposures : documenter QUI consomme le DAG en aval de dbt

[`models/marts/_marts__exposures.yml`](../../models/marts/_marts__exposures.yml) :

```yaml
exposures:
  - name: executive_revenue_dashboard
    type: dashboard
    maturity: high
    url: https://bi.example.com/dashboards/executive-revenue
    depends_on:
      - ref('fct_orders')
      - ref('dim_customers')
      - ref('dim_dates')
    owner:
      name: "Data Platform Team"
      email: data-platform@example.com
```

Une exposure n'est PAS un modele dbt (pas de SQL, rien n'est
execute — `dbt build` la montre en `NO-OP`). C'est une **declaration**
: "ce dashboard/rapport externe depend de ces modeles". Utilite
concrete :

```bash
dbt ls --select +exposure:executive_revenue_dashboard   # tout ce qui alimente ce dashboard
dbt run --select +exposure:executive_revenue_dashboard  # rebuild cible avant de livrer le dashboard
```

Avant de modifier/supprimer un modele, `grep`-ez les exposures qui en
dependent (ou utilisez `dbt ls --select <modele>+`) — c'est votre
filet de securite contre "j'ai renomme une colonne et le dashboard de
la direction est casse sans que personne ne le sache avant lundi".

## Contracts : figer la FORME d'un modele critique

[`fct_orders`](../../models/marts/core/_core__models.yml) est la
table la plus consommee en aval (BI, semantic layer, module 08). Un
changement de type de colonne ou une colonne renommee sans le
vouloir y est particulierement dangereux. D'ou :

```yaml
- name: fct_orders
  config:
    contract:
      enforced: true
  columns:
    - name: order_id
      data_type: integer
      constraints:
        - type: primary_key
        - type: not_null
    - name: item_count
      data_type: bigint
      constraints:
        - type: check
          expression: "item_count >= 0"
    ...
```

Avec `contract.enforced: true`, dbt genere le `CREATE TABLE` avec les
types et contraintes EXACTS declares, et **refuse de compiler** si le
SELECT du modele ne correspond pas exactement (colonne manquante, en
trop, ou de type different). C'est une verification a la compilation,
avant meme de toucher l'entrepot — l'echec arrive en quelques
secondes en local/CI, pas en observant une table corrompue en
production.

**Deux contraintes rencontrees en le mettant en place ici :**

1. `on_schema_change` doit valoir `append_new_columns` ou `fail` sur
   un modele incremental sous contrat (voir module 05) — dbt refuse
   `sync_all_columns`, qui pourrait faire deriver silencieusement un
   schema cense etre fige.
2. Un type sans precision explicite (`numeric` seul) declenche un
   avertissement Postgres ("unintended rounding"). Solution :
   preciser `numeric(12, 2)` dans le contrat ET caster explicitement
   dans le SQL du modele (`cast(... as numeric(12, 2))`) pour que les
   deux correspondent exactement.

## Grants : les permissions comme code

[`dim_customers`](../../models/marts/core/_core__models.yml) :

```yaml
config:
  grants:
    select: ['bi_reader']
```

A chaque `dbt run`, dbt s'assure que le role Postgres `bi_reader` a
(et SEULEMENT a) le droit `SELECT` sur cette table — cree/revoque
automatiquement les `GRANT`/`REVOKE` necessaires pour que l'etat
corresponde exactement a la config, meme si quelqu'un a bidouille les
permissions manuellement entre-temps. Le role `bi_reader` lui-meme
est cree dans
[`postgres/init-scripts/01_raw_schema.sql`](../../postgres/init-scripts/01_raw_schema.sql)
(`create role bi_reader nologin` — dbt gere les permissions, pas la
creation des roles, qui reste du ressort de l'admin warehouse).

Verifiez :

```sql
\dp "dbt_jeff_marts".dim_customers
-- dbt_jeff_marts | dim_customers | table | ...+bi_reader=r/admin_dbt_labs
```

## Un mot sur le versioning de modeles (apercu)

dbt permet de versionner un modele quand son contrat DOIT changer de
maniere incompatible (ex: renommer une colonne consommee ailleurs) :

```yaml
- name: dim_customers
  latest_version: 2
  versions:
    - v: 1
      defined_in: dim_customers_v1
    - v: 2
```

Les consommateurs peuvent alors migrer a leur rythme
(`ref('dim_customers', v=1)` vs `ref('dim_customers')` = dernier
`latest_version`). Ce projet n'en a pas besoin (un seul domaine, une
seule equipe) — c'est un outil pour la gouvernance multi-equipes
(module 10), a sortir seulement quand une rupture de contrat est
inevitable.

## Exercice

`fct_order_items` n'a pas de contrat de donnees alors qu'il est
consomme par `dim_products` ET `product_return_rates` (deux domaines
differents). Ajoutez un contrat minimal (juste les colonnes cles).

### Solution

```yaml
# models/marts/core/_core__models.yml, sous fct_order_items
  - name: fct_order_items
    config:
      contract:
        enforced: true
    columns:
      - name: order_item_id
        data_type: integer
        constraints:
          - type: primary_key
          - type: not_null
      - name: order_id
        data_type: integer
        constraints:
          - type: not_null
      - name: product_id
        data_type: integer
        constraints:
          - type: not_null
      - name: customer_id
        data_type: integer
      - name: order_status
        data_type: text
      - name: ordered_at
        data_type: timestamp
      - name: quantity
        data_type: integer
      - name: unit_price_cents
        data_type: integer
      - name: unit_price
        data_type: numeric(12, 2)
      - name: line_amount_cents
        data_type: bigint
      - name: line_amount
        data_type: numeric(12, 2)
      - name: updated_at
        data_type: timestamp
```

Un contrat sous `enforced: true` DOIT lister TOUTES les colonnes
produites par le SELECT (pas seulement celles qui vous interessent) —
dbt compare column-par-column, une colonne manquante dans le YAML
fait echouer la compilation. C'est volontairement strict : un contrat
partiel donnerait un faux sentiment de securite.

## Suite

→ [Module 08 — Semantic layer / MetricFlow](../08-semantic-layer-metricflow/README.md)
