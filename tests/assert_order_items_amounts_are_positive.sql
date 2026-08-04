-- Test singulier : aucune ligne de commande ne doit avoir un montant
-- negatif. Le test echoue si la requete retourne au moins une ligne.

select
    order_item_id,
    line_amount_cents
from {{ ref('stg_order_items') }}
where line_amount_cents < 0
