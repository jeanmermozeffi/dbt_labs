{{
    config(
        materialized='incremental',
        unique_key='order_item_id',
        incremental_strategy='delete+insert'
    )
}}

-- Table de faits, grain = 1 ligne par (commande x produit).
-- Plus fine que fct_orders : utile pour l'analyse produit (module 02)
-- et pour illustrer une deuxieme strategie incrementale (module 05).

with order_items as (

    select * from {{ ref('stg_order_items') }}

),

orders as (

    select order_id, customer_id, order_status, ordered_at, updated_at
    from {{ ref('stg_orders') }}

),

final as (

    select
        oi.order_item_id,
        oi.order_id,
        oi.product_id,
        o.customer_id,
        o.order_status,
        o.ordered_at,
        oi.quantity,
        oi.unit_price_cents,
        oi.unit_price,
        oi.line_amount_cents,
        {{ cents_to_dollars('oi.line_amount_cents') }} as line_amount,
        o.updated_at

    from order_items oi
    inner join orders o on o.order_id = oi.order_id

    {% if is_incremental() %}
    where o.updated_at > (select coalesce(max(updated_at), '1900-01-01'::timestamp) from {{ this }})
    {% endif %}

)

select * from final
