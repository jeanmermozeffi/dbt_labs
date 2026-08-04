# Module 03 — Tests et qualite de donnees

## Objectifs

- Distinguer tests generiques, singuliers, et unit tests — et savoir
  quand utiliser lequel.
- Ecrire son propre test generique reutilisable.
- Utiliser `dbt_expectations` pour des controles statistiques.
- Comprendre `severity`, `store_failures`, et la syntaxe `arguments:`.

## Les 3 familles de tests dbt

| Famille | Que teste-t-elle | Execute une requete sur l'entrepot ? |
|---|---|---|
| **Generique** (`unique`, `not_null`, `accepted_values`, `relationships`, `not_negative`...) | Une propriete d'une colonne/table, reutilisable partout via YAML | Oui |
| **Singulier** (`tests/*.sql`) | Une regle metier specifique, un fichier = un test | Oui |
| **Unit test** (`unit_tests:` en YAML, dbt >= 1.8) | La LOGIQUE d'un modele, avec des donnees fictives | Non — zero acces a l'entrepot |

## Tests generiques : la syntaxe moderne `arguments:`

```yaml
# models/staging/_staging__sources.yml
- name: customer_segment
  tests:
    - accepted_values:
        arguments:
          values: ['standard', 'vip']
```

Pourquoi `arguments:` et pas juste `values:` directement sous
`accepted_values:` (l'ancienne syntaxe, encore visible dans beaucoup
de tutoriels) ? Parce que dbt distingue maintenant strictement :

- `arguments:` → parametres passes a la macro de test elle-meme.
- `config:` → configuration dbt generique (severity, tags, where, meta...).

Sans cette separation, un test avec un argument nomme `tags` (ca
arrive) serait ambigu avec la config `tags` de dbt. Depuis dbt-core
1.10, ne pas utiliser `arguments:` declenche un avertissement de
depreciation (`MissingArgumentsPropertyInGenericTestDeprecation`) —
nous l'avons rencontre en construisant ce projet, et corrige dans
tous les fichiers YAML du repo. Utilisez toujours cette forme dans du
code neuf.

## Ecrire son propre test generique

Un test generique est juste une macro nommee `test_<nom>`, definie
avec le mot-cle `{% test %}` plutot que `{% macro %}`. Ce projet en
a un : [`macros/generic_tests/test_not_negative.sql`](../../macros/generic_tests/test_not_negative.sql) :

```sql
{% test not_negative(model, column_name) %}

select *
from {{ model }}
where {{ column_name }} < 0

{% endtest %}
```

Regle d'or : **un test dbt echoue si sa requete SQL retourne au moins
une ligne.** `model` et `column_name` sont fournis automatiquement par
dbt ; vous pouvez ajouter d'autres parametres (voir `not_null` de
dbt-core qui n'en a pas, ou `relationships` qui a `to`/`field`).

Utilisation, exactement comme un test built-in :

```yaml
- name: refund_amount_cents
  tests:
    - not_negative
```

**Quand promouvoir un test singulier en test generique ?** Des que la
meme verification (ici : "cette colonne ne doit jamais etre
negative") s'applique a plus de 2-3 colonnes/modeles differents. Ce
projet applique `not_negative` a `stg_returns.refund_amount_cents`,
`fct_orders.subtotal_cents` et `fct_orders.total_paid_cents` — trois
lignes YAML au lieu de trois fichiers `.sql` presque identiques.

## Tests singuliers : les regles qui ne se generalisent pas

[`tests/assert_payments_reconcile_with_orders.sql`](../../tests/assert_payments_reconcile_with_orders.sql) :

```sql
{{ config(severity='warn') }}

select order_id, subtotal_cents, total_paid_cents, total_paid_cents - subtotal_cents as delta_cents
from {{ ref('fct_orders') }}
where has_successful_payment
  and subtotal_cents != total_paid_cents
```

Cette regle ("le panier doit correspondre a l'encaissement") est
propre a *ce* modele *precis* — inutile d'en faire un test generique.
Notez `severity='warn'` : un ecart doit etre investigue (visible dans
les logs / dans un outil d'observabilite, module 11) mais **ne doit
pas bloquer le `dbt build`**, a la difference de `severity='error'`
(le defaut). Reservez `warn` aux regles ou un faux positif est
plausible (remise commerciale non tracee, litige en cours...) — pas
aux regles d'integrite dures (`unique`, `not_null` sur une cle
primaire restent en `error`).

Autre exemple : [`tests/assert_order_items_amounts_are_positive.sql`](../../tests/assert_order_items_amounts_are_positive.sql).

## `dbt_expectations` : des tests statistiques prets a l'emploi

Installe via [`packages.yml`](../../packages.yml). Exemple reel,
[`models/staging/_staging__sources.yml`](../../models/staging/_staging__sources.yml) :

```yaml
- name: unit_price_cents
  tests:
    - dbt_expectations.expect_column_values_to_be_between:
        arguments:
          min_value: 0
          strictly: false
```

Le namespace `dbt_expectations.` indique que le test vient d'un
package (inspire de Great Expectations). Autres tests utiles de ce
package deja utilises ici : `expect_column_values_to_be_between` sur
`return_rate` (borne entre 0 et 1, dans
[`models/marts/returns/_returns__models.yml`](../../models/marts/returns/_returns__models.yml)).
Catalogue complet : [github.com/metaplane/dbt-expectations](https://github.com/metaplane/dbt-expectations).

## Unit tests dbt (>= 1.8) : tester la LOGIQUE, pas les donnees

Les tests precedents executent une vraie requete sur vos vraies
donnees materialisees : ils vous disent "vos donnees actuelles
respectent-elles la regle ?", mais ne testent pas la logique SQL
elle-meme dans l'absolu (si `stg_order_items` a un bug qui, par
coincidence, produit quand meme des valeurs positives aujourd'hui, le
test `not_negative` ne le detectera pas). Les unit tests comblent ce
trou : on fige des lignes d'ENTREE fictives, et on verifie la sortie
EXACTE du modele — sans toucher l'entrepot, donc tres rapides.

Voir [`models/staging/_staging__unit_tests.yml`](../../models/staging/_staging__unit_tests.yml) :

```yaml
unit_tests:
  - name: test_stg_order_items_computes_line_amount
    model: stg_order_items
    overrides:
      macros:
        dbt.current_timestamp: "'2026-01-01 00:00:00'::timestamp"
    given:
      - input: source('raw', 'order_items')
        rows:
          - { order_item_id: 9001, order_id: 1, product_id: 1, quantity: 3, unit_price_cents: 1000 }
    expect:
      rows:
        - { order_item_id: 9001, order_id: 1, product_id: 1, quantity: 3, unit_price_cents: 1000, unit_price: '10.00', line_amount_cents: 3000, loaded_at: '2026-01-01 00:00:00' }
```

**Deux pieges reels rencontres en ecrivant ces tests** (donc a
connaitre par cœur) :

1. **Toute colonne de sortie absente de `expect.rows` est comparee a
   `NULL`.** Il faut lister TOUTES les colonnes produites par le
   modele, meme celles qui ne vous interessent pas pour ce test
   precis.
2. **Les valeurs numeriques doivent etre citees en chaine** :
   `unit_price: '10.00'` et pas `unit_price: 10.00`. YAML parse
   `10.00` comme le flottant `10.0`, qui perd le zero de precision —
   alors que Postgres renvoie une vraie valeur `numeric` a 2
   decimales. Le mismatch de representation textuelle fait echouer le
   test alors que les deux valeurs sont numeriquement egales.
3. **Colonnes non-deterministes** (`loaded_at` via
   `{{ dbt.current_timestamp() }}`) : figez-les avec
   `overrides.macros`, sinon le test echoue a chaque execution a une
   seconde pres.

Executer uniquement les unit tests (rapide, ideal en pre-commit/CI) :

```bash
dbt test --select test_type:unit
```

## Lire un test qui echoue

C'est la competence operationnelle la plus utilisee de ce module, et
la sortie de dbt n'est pas evidente au premier coup d'œil. Exemple
reel, produit en corrompant volontairement un prix
(`update raw.products set unit_price_cents = -500 where product_id = 1`) :

```
3 of 6 FAIL 1 dbt_expectations_expect_column_values_to_be_between_stg_products_unit_price__0  [FAIL 1 in 0.08s]

Completed with 1 error, 0 partial successes, and 0 warnings:

Failure in test dbt_expectations_expect_column_values_to_be_between_stg_products_unit_price__0 (models/staging/_staging__models.yml)
  Got 1 result, configured to fail if != 0

  compiled code at target/compiled/dbt_labs/models/staging/_staging__models.yml/dbt_expectations_expect_column_eef32200e0fe0956a2ff1b713cf56095.sql

Done. PASS=5 WARN=0 ERROR=1 SKIP=0 NO-OP=0 TOTAL=6
```

Quatre choses a savoir pour exploiter ca :

**1. Le nom du test est genere automatiquement**, selon le patron
`<type_de_test>_<modele>_<colonne>__<arguments>` :

```
accepted_values_stg_products_price_tier__budget__mid__premium
^^^^^^^^^^^^^^^ ^^^^^^^^^^^^ ^^^^^^^^^^  ^^^^^^^^^^^^^^^^^^^
type            modele       colonne     valeurs autorisees
```

Vous pouvez donc identifier ce qui a casse **sans ouvrir un seul
fichier**. Si un nom devient illisible (cas de `dbt_expectations`,
tronque et suffixe d'un hash), ajoutez `name:` sous le test pour le
nommer vous-meme.

**2. `Got 1 result, configured to fail if != 0`** est la formulation
standard, et elle decoule directement de la regle d'or : un test est
une requete qui cherche des **contre-exemples**. 1 resultat = 1 ligne
fautive. Ce n'est jamais "1 test a echoue" — c'est "1 ligne viole la
regle".

**3. Le chemin `compiled code at target/compiled/...`** est le plus
utile de tout le bloc : c'est le SQL exact que dbt a execute. Ouvrez-le
et lancez-le vous-meme pour voir les lignes fautives :

```bash
psql ... -f target/compiled/dbt_labs/models/staging/_staging__models.yml/dbt_expectations_....sql
```

Sur les tests que vous consultez souvent, `store_failures=true`
(module 11) evite ce detour en materialisant directement les lignes
fautives dans une table.

**4. `ERROR=1` mais `SKIP=0`** ici parce que rien ne dependait de ce
test. Dans un `dbt build` complet, un test en echec sur `stg_products`
mettrait `dim_products` et tout son aval en `SKIP` — c'est le
comportement recherche, et la raison d'utiliser `build` plutot que
`run` puis `test`.

## Ou tester quoi ? (strategie de couverture)

1. **Sources** (`_staging__sources.yml`) : `not_null`/`unique` sur
   les cles, `relationships` vers les seeds de reference. On veut
   savoir le plus tot possible si le systeme source a change.
2. **Staging** : `accepted_values` sur les colonnes categorielles
   normalisees (le vocabulaire canonique du projet se decide ici).
3. **Marts** : `unique`/`not_null` sur les cles de dimension, plus
   les regles metier transverses (reconciliation, bornes).
4. **Unit tests** : la ou la logique SQL est non triviale (pivots,
   cas `case when` multiples, calculs) — la ou un review humain seul
   ne suffit pas a garantir la correction.

## Exercice

`dim_products.orders_count` devrait toujours etre >= `0` ET un
produit `is_active = false` ne devrait jamais apparaitre dans une
commande `placed` (une commande passee aujourd'hui sur un produit
retire du catalogue = anomalie). Ecrivez :

1. Un test generique reutilisant `not_negative` sur `orders_count`.
2. Un test singulier pour la regle "produit inactif + commande
   placee".

### Solution

```yaml
# models/marts/core/_core__models.yml, sous dim_products
      - name: orders_count
        tests:
          - not_negative
```

```sql
-- tests/assert_no_placed_orders_on_inactive_products.sql
select
    oi.order_id,
    oi.product_id,
    p.product_name
from {{ ref('fct_order_items') }} oi
inner join {{ ref('dim_products') }} p on p.product_id = oi.product_id
where oi.order_status = 'placed'
  and p.is_active = false
```

Ce test singulier illustre pourquoi il ne peut PAS etre generique :
la regle croise deux modeles (`fct_order_items` et `dim_products`)
avec une condition composee — un test generique prend un seul
`model`/`column_name`, il ne peut pas exprimer nativement "sur un
AUTRE modele, une valeur associee doit valoir X".

#### Lancez-le : il ECHOUE. Et c'est tout l'interet.

```bash
dbt test --select assert_no_placed_orders_on_inactive_products
```

```
1 of 1 FAIL 1 assert_no_placed_orders_on_inactive_products [FAIL 1 in 0.03s]
Done. PASS=0 WARN=0 ERROR=1 SKIP=0 NO-OP=0 TOTAL=1
```

Ne corrigez pas votre SQL : il est juste. Le test a fait son travail,
il a **trouve quelque chose**. Allez voir quoi :

```
 order_id | product_id |    product_name
----------+------------+--------------------
       33 |         15 | Puzzle 1000 pieces
```

Un test rouge pose toujours la meme question, et ce n'est jamais
"comment le faire passer" : **la donnee est-elle fausse, ou la regle
est-elle fausse ?** Ici, remontez a la source :

```sql
select p.product_id, p.is_active, o.order_id, o.order_status, o.ordered_at
from raw.products p
join raw.order_items oi on oi.product_id = p.product_id
join raw.orders o on o.order_id = oi.order_id
where p.is_active = false and o.order_status = 'placed';
```

```
 product_id | is_active | order_id | order_status |   ordered_at
------------+-----------+----------+--------------+---------------------
         15 | f         |       33 | placed       | 2026-06-01 09:00:00
```

**La regle est fausse.** Elle compare deux choses de nature
differente :

| Element | Nature |
|---|---|
| `dim_products.is_active` | l'etat **ACTUEL** du produit (dimension Type 1, aucun historique) |
| `order_status = 'placed'` | un evenement **PASSE** |

Un produit retire du catalogue *apres* qu'une commande a ete passee
dessus est un scenario parfaitement normal. Le test le signale comme
une anomalie parce qu'il suppose, implicitement, que `is_active`
valait deja `false` au moment de la commande — ce que rien ne permet
d'affirmer. `raw.products` n'a meme pas de colonne `updated_at` : on
ne peut pas savoir QUAND le produit a ete desactive.

C'est une erreur de modelisation classique et couteuse :
**confronter un attribut courant a un fait historique**. Deux sorties
legitimes :

1. **Assumer que c'est un signal, pas une violation d'integrite** —
   `{{ config(severity='warn') }}`. Quelqu'un doit regarder, mais ca
   ne doit pas bloquer un deploiement.
2. **Rendre la question repondable** — historiser `is_active` avec un
   snapshot SCD2, puis tester "le produit etait-il actif A LA DATE de
   la commande ?". C'est exactement l'objet de l'exercice du
   [module 06](../06-snapshots-scd/README.md), et la raison pour
   laquelle il utilise `strategy='check'` : sans `updated_at` fiable,
   c'est la seule facon de dater le changement.

Retenez la sequence, elle vaut pour tous vos tests rouges en
production : **lire les lignes fautives → remonter a la source →
decider si c'est la donnee ou la regle → seulement ensuite, agir.**

#### Un mot sur la premiere partie de l'exercice

`not_negative` sur `dim_products.orders_count` passe — mais
regardez pourquoi :

```sql
-- models/marts/core/dim_products.sql
count(distinct order_id) as orders_count,
...
coalesce(ps.orders_count, 0) as orders_count,
```

Un `count()` ne peut pas etre negatif, et le `coalesce(..., 0)`
elimine le seul autre cas possible. **Ce test ne peut structurellement
jamais echouer.** Il n'est pas nuisible, mais il ne protege de rien :
il documente une intention deja garantie par le SQL.

Un test qui ne peut pas echouer donne un faux sentiment de couverture.
Avant d'ajouter un test, posez-vous : *quel bug realiste ce test
attraperait-il ?* Si vous ne savez pas repondre, le test appartient
plutot a une colonne dont la valeur vient de l'exterieur (une source,
un calcul non borne) qu'a un agregat que vous venez de contraindre
vous-meme.

## Suite

→ [Module 04 — Jinja et macros avancees](../04-jinja-macros-avancees/README.md)
