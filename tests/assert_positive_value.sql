-- Ce test vérifie qu'il n'y a pas de montants négatifs
-- Le test échoue si des lignes sont retournées

select
    order_id,
    order_amount
from {{ ref('stg_orders') }}
where order_amount < 0
