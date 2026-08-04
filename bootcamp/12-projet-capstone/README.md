# Module 12 — Projet capstone : le domaine "returns"

## Objectif

Vous n'etes plus guide pas-a-pas. Voici un cahier des charges, comme
en entreprise. Faites-le VOUS-MEME avant d'ouvrir
[`solution/README.md`](solution/README.md) — ce module ne vaut que si
vous avez transpire dessus d'abord.

**Contexte metier** : l'equipe Customer Experience veut suivre les
retours produits — quel produit se fait le plus retourner, pour
combien, et pourquoi — sans attendre un export manuel chaque
semaine.

**Donnee source deja disponible** : `raw.returns` existe deja dans
`postgres/init-scripts/01_raw_schema.sql` (`return_id`,
`order_item_id`, `reason`, `refund_amount_cents`, `returned_at`).
Elle contient un retour pour un sous-ensemble des lignes de commandes
dont le statut est `'returned'`.

## Cahier des charges

Livrez un domaine `returns` complet et production-ready, en
reutilisant tout ce que vous avez appris aux modules 01-11.

### 1. Couche staging

- `stg_returns` : renommage/cast standard de `raw.returns`, rien de
  plus (module 01/02).
- Declarer la source dans le YAML, avec au minimum `unique`/`not_null`
  sur `return_id` et une `relationships` vers les order items (module 03).

### 2. Table de faits

- `fct_returns`, grain = 1 ligne par retour, enrichie de `order_id`
  et `product_id` (recuperes depuis les order items).
- Materialisation **incrementale**, avec la strategie la plus legere
  justifiable pour un evenement immuable (module 05 — vous avez deja
  fait cet exercice sur le papier, il faut maintenant le livrer pour
  de vrai).

### 3. Mart d'agregation

- `product_return_rates`, grain = 1 ligne par produit :
  `items_sold`, `items_returned`, `return_rate` (0 a 1),
  `refunded_amount_cents`/`refunded_amount`. Attention a la division
  par zero pour un produit jamais vendu (module 02).
- **Contrat de donnees applique** (module 07) : tous les types
  explicites, cle primaire contrainte.
- **Grants** : le role `bi_reader` doit pouvoir lire ce mart (module 07).

### 4. Tests

- Au moins un test **generique reutilisable** (pas un package tiers —
  un que VOUS ecrivez, module 03).
- Au moins un test verifiant que `return_rate` reste dans `[0, 1]`.

### 5. Gouvernance

- Ce domaine appartient a une equipe differente de `core`. Creez le
  groupe qui va bien, assignez-le, et verifiez qu'un mauvais choix
  d'`access` casse bien la compilation comme attendu (module 10).

### 6. Semantic layer

- Un `semantic_model` sur la table de faits des retours (pas sur le
  mart agrege — reflechissez a pourquoi les measures doivent porter
  sur le grain le plus fin possible, module 08).
- Deux `metrics` minimum : nombre de retours, montant total rembourse.

### 7. Exposure

- Une `exposure` documentant qui consomme `product_return_rates`
  (module 07).

## Criteres d'acceptation

Chaque commande doit passer, et vous devez savoir **lire** ce qu'elle
repond (voir [reference-cli.md](../reference-cli.md)) :

```bash
dbt parse
# valide les semantic models/metrics ET la structure des YAML.
# A lancer en PREMIER : echoue en 2 s, sans toucher l'entrepot.

dbt build
# Done. PASS=99 WARN=0 ERROR=0 SKIP=0 NO-OP=2 TOTAL=101
#            ^ 0 partout sauf NO-OP (= les 2 exposures, normal)
#       un seul SKIP signifie qu'un test amont a echoue : remontez-y

dbt source freshness
# 6 of 6 PASS  (si ERROR : votre conteneur tourne depuis > 72 h,
#                voir le module 07, ce n'est pas votre code)

dbt ls --select +exposure:product_return_rate_report --resource-type model
# dbt_labs.marts.core.dim_products
# dbt_labs.marts.core.fct_order_items
# dbt_labs.marts.returns.fct_returns
# dbt_labs.marts.returns.product_return_rates
# dbt_labs.staging.stg_order_items
# dbt_labs.staging.stg_orders
# dbt_labs.staging.stg_products
# dbt_labs.staging.stg_returns
#
# 8 modeles. Verifiez-les un par un : chacun doit avoir une raison
# d'etre la. Un modele inattendu = une dependance parasite dans votre
# SQL (un ref() oublie dans une CTE devenue inutile, typiquement).

dbt ls --select product_return_rates --resource-type test
# verifiez que TOUS les tests que vous croyez avoir ecrits existent
# vraiment (piege du module 01 : un YAML mal indente ne dit rien)
```

Et une question a laquelle vous devez pouvoir repondre sans requeter
manuellement : **"quel produit a le pire taux de retour, et est-ce
significatif (au moins N commandes) ou juste du bruit statistique sur
un petit volume ?"**

## Quand vous avez fini (ou quand vous etes bloque·e)

Ouvrez [`solution/README.md`](solution/README.md) : le code qui y est
documente est **exactement celui qui tourne dans ce repo** (`models/marts/returns/`),
valide par un `dbt build` reel avant d'etre ecrit ici — comparez-le
au votre point par point plutot que de le copier-coller directement.

## Suite

Vous avez termine le parcours guide. Prochaine etape naturelle :
prenez un VRAI jeu de donnees d'un projet perso ou professionnel, et
rejouez l'integralite de ce bootcamp dessus, module par module, sans
filet. C'est la que ca devient reellement acquis.

Voir aussi [`../glossaire.md`](../glossaire.md) et
[`../ressources.md`](../ressources.md).
