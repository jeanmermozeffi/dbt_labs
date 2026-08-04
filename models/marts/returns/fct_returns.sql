{{
    config(
        materialized='incremental',
        incremental_strategy='append',
    )
}}

-- Table de faits, grain = 1 ligne par retour. Flux d'evenements
-- immuable (un retour n'est jamais modifie une fois enregistre) :
-- strategie 'append', pas 'delete+insert' (voir bootcamp/05).

with returns as (

    select * from {{ ref('stg_returns') }}

    {% if is_incremental() %}
    where returned_at > (select coalesce(max(returned_at), '1900-01-01'::timestamp) from {{ this }})
    {% endif %}

),

order_items as (

    select order_item_id, order_id, product_id
    from {{ ref('stg_order_items') }}

),

final as (

    select
        r.return_id,
        r.order_item_id,
        oi.order_id,
        oi.product_id,
        r.reason,
        r.refund_amount_cents,
        r.returned_at

    from returns r
    inner join order_items oi on oi.order_item_id = r.order_item_id

)

select * from final
