{{ config(severity='warn', store_failures=true, schema='dbt_test_failures') }}

-- Test singulier "business rule" : pour une commande dont le paiement
-- a reussi, le montant encaisse doit correspondre au sous-total des
-- lignes de commande. severity=warn : un ecart doit etre investigue
-- mais ne doit pas bloquer le run (a la difference d'un test en
-- severity=error, le comportement par defaut).

select
    order_id,
    subtotal_cents,
    total_paid_cents,
    total_paid_cents - subtotal_cents as delta_cents
from {{ ref('fct_orders') }}
where has_successful_payment
  and subtotal_cents != total_paid_cents
