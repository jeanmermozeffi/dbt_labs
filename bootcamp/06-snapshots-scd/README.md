# Module 06 — Snapshots et Slowly Changing Dimensions

## Objectifs

- Comprendre les types de SCD (Slowly Changing Dimensions) et pourquoi le type 2 domine en pratique.
- Ecrire et executer un snapshot dbt avec la strategie `timestamp`.
- Comprendre `dbt_valid_from`/`dbt_valid_to` et interroger l'historique.
- Savoir choisir entre strategie `timestamp` et `check`.

## Le probleme que les snapshots resolvent

`raw.customers` est une photo de l'etat ACTUEL. Si un client passe de
`standard` a `vip` aujourd'hui, la ligne est ecrasee — l'information
"il etait standard jusqu'au 24/07" disparait a jamais des que vous
relancez `dbt run`. Or beaucoup d'analyses en ont besoin : "quel
etait le segment du client au moment de CETTE commande passee il y a
3 mois ?"

## Les types de SCD (rappel rapide)

| Type | Comportement | Cout |
|---|---|---|
| **Type 0** | Jamais mis a jour (immuable) | Nul |
| **Type 1** | Ecrase la valeur, aucun historique | Nul (c'est `raw.customers` tel quel) |
| **Type 2** | Nouvelle ligne a chaque changement, avec periode de validite | Stockage qui grossit dans le temps |
| **Type 3** | Une colonne "valeur precedente" en plus | Ne garde qu'1 changement de profondeur |

**Les snapshots dbt implementent le Type 2**, le plus utilise en
pratique car il ne perd aucune information et reste interrogeable en
SQL simple (`where date between dbt_valid_from and
coalesce(dbt_valid_to, 'infinity')`).

## Le snapshot de ce projet

[`snapshots/scd_customers.sql`](../../snapshots/scd_customers.sql) :

```sql
{% snapshot scd_customers %}

{{
    config(
        target_schema='snapshots',
        unique_key='customer_id',
        strategy='timestamp',
        updated_at='updated_at',
        invalidate_hard_deletes=True,
    )
}}

select * from {{ source('raw', 'customers') }}

{% endsnapshot %}
```

Points cles :

- **On snapshotte la SOURCE brute**, pas `stg_customers`. Le
  staging peut changer de forme (renommages, nouvelles colonnes
  calculees) sans casser l'historique — l'historique doit rester fidele
  a la verite operationnelle brute, pas a une couche de transformation
  qui peut evoluer.
- **`target_schema` est utilise LITTERALEMENT**, sans passer par la
  macro `generate_schema_name` (module 04) — c'est un comportement
  special de dbt pour les snapshots. Verifiez-le vous-meme :

  ```bash
  dbt snapshot
  # 1 of 1 OK snapshotted snapshots.scd_customers [INSERT 0 0 in 0.16s]
  #                       ^^^^^^^^^ pas "dbt_jeff_snapshots"
  ```

  **Consequence a mesurer** : contrairement aux modeles, deux
  developpeurs partageant la meme base ecrivent dans le **meme**
  snapshot. En equipe, cela veut dire un historique commun (parfois
  souhaitable) ou des collisions (rarement souhaitable) — a decider
  consciemment, pas a subir.

  `INSERT 0 0` au second run n'est pas une erreur : c'est le
  comportement normal quand aucune ligne source n'a change depuis le
  dernier snapshot.
- **`strategy='timestamp'` + `updated_at='updated_at'`** : dbt
  compare, a chaque `dbt snapshot`, le `updated_at` de la ligne
  source au `updated_at` de la derniere version connue. Different →
  nouvelle version.
- **`invalidate_hard_deletes=True`** : si une ligne disparait
  completement de `raw.customers` (suppression physique, pas juste
  une mise a jour), dbt cloture sa version courante
  (`dbt_valid_to = maintenant`) au lieu de la laisser "valide pour
  toujours" a tort.

## Demonstration reelle (executee pour valider ce projet)

```bash
dbt snapshot   # premiere execution : 1 ligne par client, dbt_valid_to = NULL

# on simule un changement metier
psql ... -c "update raw.customers set customer_segment='vip', updated_at=now() where customer_id=2;"

dbt snapshot   # deuxieme execution
```

Resultat observe dans `snapshots.scd_customers` :

```
 customer_id | customer_segment |       dbt_valid_from       |       dbt_valid_to
-------------+------------------+----------------------------+----------------------------
           2 | standard         | 2025-12-26 15:20:32.139687 | 2026-07-24 15:22:22.49613
           2 | vip              | 2026-07-24 15:22:22.49613  |
```

Deux versions, periode de validite continue (le `dbt_valid_to` de la
premiere = `dbt_valid_from` de la seconde), la version courante a
`dbt_valid_to IS NULL`. Requete typique "etat au 1er janvier 2026" :

```sql
select *
from snapshots.scd_customers
where dbt_valid_from <= '2026-01-01'
  and (dbt_valid_to > '2026-01-01' or dbt_valid_to is null)
```

## `timestamp` vs `check` : quelle strategie choisir ?

- **`timestamp`** : la source a une colonne fiable de derniere
  modification (`updated_at`). C'est le cas ideal — rapide, fiable,
  utilise ici.
- **`check`** (`check_cols=['col_a', 'col_b']` ou `check_cols='all'`) :
  aucune colonne de date fiable. dbt compare les valeurs elles-memes
  entre deux runs. Plus lourd (compare colonne par colonne a chaque
  run) et fragile si vous oubliez une colonne dans `check_cols`.

Regle pratique : **preferez toujours `timestamp` si vous avez un
`updated_at` fiable.** N'utilisez `check` qu'en dernier recours (source
legacy sans horodatage de modification).

## Pieges frequents

1. **Snapshotter un modele `ephemeral`** : impossible, un snapshot a
   besoin d'un objet materialise interrogeable (source ou table/vue).
2. **Changer `unique_key` ou `strategy` apres coup** : dbt ne
   "migre" jamais un snapshot existant — changer sa config sans
   supprimer/reconstruire la table cible produit un historique
   incoherent. Traitez la config d'un snapshot comme quasi-immuable
   une fois en production.
3. **Mal comprendre la place des snapshots dans `dbt build`.**
   Verifions plutot que de supposer :

   ```bash
   dbt build
   # Finished running 2 exposures, 3 incremental models, 2 seeds,
   #     1 snapshot, 4 table models, 80 data tests, ...
   ```

   `dbt build` **execute bien les snapshots** — ils sont ordonnances
   comme n'importe quel autre noeud, a leur place dans le DAG. Le
   vrai piege est ailleurs, et il est plus subtil : **la position d'un
   snapshot dans le DAG est rarement celle qu'on veut.**

   Un snapshot lit `source('raw', 'customers')` : il n'a donc aucun
   parent dbt, et rien ne garantit qu'il tourne **avant** les modeles
   qui, eux, lisent la meme source. Si votre besoin est "historiser
   l'etat de la source avant toute transformation", `dbt build` seul
   ne vous le garantit pas — d'ou le `dbt snapshot` explicite en
   amont dans la CI de ce projet :

   ```bash
   dbt deps && dbt seed && dbt snapshot && dbt build
   ```

   Le symptome quand on se trompe : l'historique presente des trous ou
   des versions decalees d'un run, alors que `dbt run`/`dbt test`
   passent au vert. Rien ne vous alerte.

4. **`invalidate_hard_deletes` est la syntaxe historique.** Depuis
   dbt-core 1.9, la config recommandee est `hard_deletes` :

   ```python
   hard_deletes='invalidate'   # equivaut a invalidate_hard_deletes=True
   hard_deletes='new_record'   # ajoute une ligne marquee comme supprimee
   hard_deletes='ignore'       # defaut : les suppressions passent inapercues
   ```

   `invalidate_hard_deletes=True` (utilise dans ce projet) reste
   accepte et fonctionnel — mais dans du code neuf, preferez
   `hard_deletes`, plus expressif et seul a offrir l'option
   `new_record`.

## Exercice

Un produit peut etre desactive (`is_active` passe a `false`) puis
reactive. `raw.products` n'a pas de colonne `updated_at` fiable pour
ce champ specifique. Ecrivez un second snapshot,
`snapshots/scd_products.sql`, qui historise `is_active` avec la
strategie adaptee.

### Solution

```sql
{% snapshot scd_products %}

{{
    config(
        target_schema='snapshots',
        unique_key='product_id',
        strategy='check',
        check_cols=['is_active', 'unit_price_cents'],
    )
}}

select * from {{ source('raw', 'products') }}

{% endsnapshot %}
```

Pourquoi `check` ici et pas `timestamp` : `raw.products` a bien une
colonne `created_at`, mais **jamais mise a jour** lors d'un
changement de `is_active` ou de prix (regardez le schema dans
`postgres/init-scripts/01_raw_schema.sql` : `created_at` est fixe a
l'insertion). Utiliser `strategy='timestamp'` avec `updated_at='created_at'`
compilerait, mais ne detecterait JAMAIS aucun changement (la valeur
ne bouge jamais) — un bug totalement silencieux. `check_cols` compare
directement les valeurs `is_active` et `unit_price_cents` a chaque
run : plus couteux mais correct. Limiter `check_cols` a ces deux
colonnes (plutot que `'all'`) evite de creer une nouvelle version a
chaque changement de `product_name` (une simple correction
orthographique ne merite pas un nouveau segment SCD2).

## Suite

→ [Module 07 — Sources, freshness, exposures, contracts](../07-sources-freshness-exposures-contracts/README.md)
