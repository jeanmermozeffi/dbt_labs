# Module 04 — Jinja et macros avancees

## Objectifs

- Ecrire des macros avec arguments par defaut et composition.
- Generer du SQL dynamiquement avec `{% for %}` / `{% if %}`.
- Interroger l'entrepot **a la compilation** avec `run_query`.
- Utiliser et comprendre `dbt_utils.pivot`.
- Surcharger une macro globale de dbt (`generate_schema_name`).

## dbt = Jinja + SQL. Le piege qu'on a laisse volontairement dans ce projet

Ouvrez [`macros/cents_to_dollars.sql`](../../macros/cents_to_dollars.sql).
Sa toute premiere version (avant qu'on la corrige en construisant ce
bootcamp) etait :

```sql
{% macro cents_to_dollars(column_name, decimal_places=2) %}
    round({{ column_name }} / 100, {{ decimal_places }})
{% endmacro %}
```

Ca compile sans erreur. Ca marche meme... parfois. Le bug : Jinja ne
sait RIEN du typage SQL — `{{ column_name }} / 100` est juste du
texte injecte tel quel. Sur Postgres, `entier / entier` fait une
**division entiere** : `2499 / 100 = 24`, pas `24.99`. La version
corrigee force le cast :

```sql
{% macro cents_to_dollars(column_name, decimal_places=2) %}
    round(({{ column_name }})::numeric / 100, {{ decimal_places }})
{% endmacro %}
```

**La lecon a retenir** : une macro dbt ne fait AUCUNE verification de
type. Elle produit du texte. Le SQL genere doit etre correct par
lui-meme — testez toujours `dbt compile --select <modele>` et lisez
le SQL final dans `target/compiled/` avant de faire confiance a une
macro numerique.

## Macros avec argument par defaut + composition

[`macros/pretty_currency.sql`](../../macros/pretty_currency.sql) :

```sql
{% macro pretty_currency(cents_column, currency_symbol='$') %}
    ('{{ currency_symbol }}' || to_char({{ cents_to_dollars(cents_column) }}, 'FM999,999,990.00'))
{% endmacro %}
```

Deux idees ici :
- `currency_symbol='$'` : argument optionnel, `pretty_currency('x')`
  et `pretty_currency('x', '€')` sont tous deux valides.
- **Composition** : `pretty_currency` appelle `cents_to_dollars` a
  l'interieur. Une macro peut en appeler une autre exactement comme
  une fonction — pas de limite de profondeur, mais gardez ca lisible
  (2-3 niveaux max en pratique).

Utilisee dans [`analyses/revenue_by_country.sql`](../../analyses/revenue_by_country.sql) —
le dossier `analyses/` compile du SQL (`dbt compile --select
revenue_by_country`) sans jamais materialiser d'objet en base : ideal
pour des requetes exploratoires versionnees dans git.

## `run_query` : interroger l'entrepot A LA COMPILATION

Le pattern le plus "magique" de dbt. [`macros/get_payment_methods.sql`](../../macros/get_payment_methods.sql) :

```sql
{% macro get_payment_methods() %}

    {% set payment_methods_query %}
        select distinct payment_method
        from {{ ref('stg_payments') }}
        order by 1
    {% endset %}

    {% if execute %}
        {% set results = run_query(payment_methods_query) %}
        {% set payment_methods = results.columns[0].values() %}
    {% else %}
        {% set payment_methods = [] %}
    {% endif %}

    {{ return(payment_methods) }}

{% endmacro %}
```

Deroule : `{% set ... %}...{% endset %}` capture du SQL dans une
variable Jinja (sans l'executer). `run_query()` l'envoie reellement a
Postgres et retourne un objet [Agate](https://agate.readthedocs.io/)
table. `results.columns[0].values()` extrait la premiere colonne en
liste Python. `{{ return(...) }}` fait sortir cette valeur de la
macro (contrairement a `{{ }}` seul, qui insere du TEXTE dans le SQL
compile).

**Le garde-fou `{% if execute %}` est obligatoire.** Lors d'un `dbt
parse` ou d'un `dbt compile` "a froid" (pas de vraie execution, par
exemple pour generer juste le manifest), `execute` vaut `False` et
aucune requete ne peut partir vers l'entrepot — sans ce garde-fou,
`run_query` plante la moindre commande dbt qui ne touche pas
l'entrepot, y compris des commandes internes utilisees par des outils
tiers (IDE dbt, linters...).

`get_payment_methods()` pilote ensuite `dbt_utils.pivot` dans
[`int_payments_pivoted.sql`](../../models/intermediate/int_payments_pivoted.sql) :
la liste des moyens de paiement n'est **jamais codee en dur** — si
demain un `payment_method` `'crypto'` apparait en base, le pivot
s'adapte automatiquement au prochain `dbt run`, sans toucher au code.

## Comprendre `dbt_utils.pivot` en le reecrivant a la main

`dbt_utils.pivot(column='payment_method', values=[...], then_value='amount_cents', else_value=0, suffix='_amount_cents')`
genere, pour chaque valeur, une colonne
`sum(case when payment_method = 'x' then amount_cents else 0 end) as x_amount_cents`.
C'est exactement le pattern `{% for %}` que vous ecririez a la main :

```sql
select
    order_id,
    {% for method in get_payment_methods() %}
    sum(case when payment_method = '{{ method }}' then amount_cents else 0 end) as {{ method }}_amount_cents{% if not loop.last %},{% endif %}
    {% endfor %}
from {{ ref('stg_payments') }}
group by order_id
```

`loop.last` (variable Jinja automatique dans une boucle `{% for %}`)
evite une virgule finale en trop apres la derniere colonne generee —
piege classique de la generation de SQL par boucle.

## Surcharger une macro globale de dbt : `generate_schema_name`

[`macros/generate_schema_name.sql`](../../macros/generate_schema_name.sql)
remplace le comportement par defaut de dbt pour la resolution des
schemas. C'est LE snippet standard recommande par dbt Labs :

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}
        {{ default_schema }}
    {%- else -%}
        {%- if target.name == 'prod' -%}
            {{ custom_schema_name | trim }}
        {%- else -%}
            {{ default_schema }}_{{ custom_schema_name | trim }}
        {%- endif -%}
    {%- endif -%}
{%- endmacro %}
```

Pourquoi c'est important : par defaut, dbt genere TOUJOURS
`{{ target.schema }}_{{ custom_schema }}`, quel que soit
l'environnement. En prod, on veut des schemas propres (`marts`,
`staging`), sans le prefixe de l'utilisateur/target. Ce snippet ne
change le comportement qu'en prod (`target.name == 'prod'`) ; en dev,
le comportement par defaut de dbt (prefixe + suffixe) est conserve —
c'est ce que vous observez dans ce projet : les tables vont dans
`dbt_jeff_marts`, `dbt_jeff_staging`, etc. — ou `dbt_jeff` est la
valeur de `POSTGRES_SCHEMA` de VOTRE `.env`, et `marts`/`staging` le
`+schema:` du dossier dans `dbt_project.yml`. Chaque developpeur
ayant sa propre valeur, deux personnes peuvent travailler sur la meme
base sans jamais s'ecraser.

**Note sur `-` dans `{%- ... -%}`** : controle du whitespace Jinja.
`{%-` supprime les espaces/retours a la ligne AVANT la balise, `-%}`
ceux APRES. Indispensable ici : sans ca, le nom de schema genere
contiendrait des espaces/retours a la ligne invisibles, ce qui casse
silencieusement des noms d'objets SQL.

## Packages de macros

[`packages.yml`](../../packages.yml) installe trois packages via
`dbt deps` (peuple `dbt_packages/`, gitignore) :

- **`dbt-labs/dbt_utils`** — boite a outils generique (`pivot`,
  `date_spine`, `generate_surrogate_key`, `get_column_values`...).
- **`metaplane/dbt_expectations`** — tests statistiques (module 03).
- **`dbt-labs/codegen`** — genere du YAML/SQL a partir du catalogue
  reel.

### `dbt run-operation` : appeler une macro sans passer par un modele

C'est la commande qui manquait a votre panoplie : elle execute une
macro **directement**, hors de tout modele. Utile pour les macros qui
font un effet de bord (maintenance, generation de code) plutot que de
produire du SQL a materialiser.

```bash
dbt run-operation generate_model_yaml --args '{"model_names": ["stg_products"]}'
```

```yaml
models:
  - name: stg_products
    description: ""
    columns:
      - name: product_id
        data_type: integer
        description: ""
      - name: price_tier
        data_type: text
        description: ""
      ...
```

Copiez cette sortie dans votre fichier de proprietes puis remplissez
les `description` — bien plus fiable que de lister les colonnes a la
main (et les `data_type` sont ceux **reellement** presents en base,
ce qui est precieux pour ecrire un contrat, module 07).

**Attention au nom de l'argument** : c'est `model_names`, **au
pluriel et sous forme de liste**. La forme singuliere echoue avec un
message peu parlant :

```
$ dbt run-operation generate_model_yaml --args '{"model_name": "dim_customers"}'
Compilation Error
  macro 'dbt_macro__generate_model_yaml' takes no keyword argument 'model_name'
```

Le `--args` est du YAML/JSON passe tel quel a la macro : les noms
doivent correspondre **exactement** a la signature de celle-ci. En cas
de doute, lisez la macro dans `dbt_packages/codegen/macros/`.

Prerequis pour que les `data_type` soient renseignes : la table doit
exister en base (`dbt run`) — codegen lit le catalogue de l'entrepot,
pas votre SQL.

## Exercice

Sans utiliser `dbt_utils.pivot`, ecrivez a la main (boucle `{% for
%}`) un modele `models/marts/core/category_units_sold.sql` : une
seule ligne par produit, avec une colonne par categorie contenant la
quantite vendue de ce produit SI il appartient a cette categorie,
sinon 0. Utilisez une macro `get_product_categories()` (a ecrire, sur
le modele de `get_payment_methods()`).

### Solution

```sql
-- macros/get_product_categories.sql
{% macro get_product_categories() %}

    {% set categories_query %}
        select distinct category
        from {{ ref('stg_products') }}
        order by 1
    {% endset %}

    {% if execute %}
        {% set results = run_query(categories_query) %}
        {% set categories = results.columns[0].values() %}
    {% else %}
        {% set categories = [] %}
    {% endif %}

    {{ return(categories) }}

{% endmacro %}
```

```sql
-- models/marts/core/category_units_sold.sql
with products as (

    select * from {{ ref('dim_products') }}

),

final as (

    select
        product_id,
        product_name,
        category,
        {% for cat in get_product_categories() %}
        case when category = '{{ cat }}' then units_sold else 0 end as units_sold_{{ cat | replace(' ', '_') | replace('&', 'and') | lower }}{% if not loop.last %},{% endif %}
        {% endfor %}
    from products

)

select * from final
```

Point d'attention specifique a ce jeu de donnees : la categorie
`"Home & Kitchen"` contient une esperluette et un espace, invalides
dans un nom de colonne SQL sans guillemets. `| replace(' ', '_') |
replace('&', 'and') | lower` (filtres Jinja, chainables comme en
Python) nettoie la valeur avant de l'utiliser comme identifiant —
c'est exactement le genre de detail que `dbt_utils.pivot` gere deja
pour vous via son parametre `quote_identifiers`, et pourquoi on
prefere le package en pratique une fois le mecanisme compris.

## Suite

→ [Module 05 — Incremental et performance](../05-incremental-performance/README.md)
