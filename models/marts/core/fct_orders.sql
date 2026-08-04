{{
    config(
        materialized='incremental',
        unique_key='order_id',
        incremental_strategy='delete+insert',
        on_schema_change='append_new_columns',
        indexes=[
            {'columns': ['order_id'], 'unique': true},
            {'columns': ['customer_id']}
        ]
    )
}}

-- Table de faits, grain = 1 ligne par commande.
-- Incrementale : a chaque run, on ne retraite que les commandes dont
-- updated_at est posterieur au max(updated_at) deja charge (pattern
-- "high-water mark"). Voir bootcamp/05-materialisations-incrementales-performance.

with orders as (

    select * from {{ ref('stg_orders') }}

    {% if is_incremental() %}
    where updated_at > (select coalesce(max(updated_at), '1900-01-01'::timestamp) from {{ this }})
    {% endif %}

),

order_amounts as (

    select * from {{ ref('int_order_amounts') }}

),

payments_pivoted as (

    select * from {{ ref('int_payments_pivoted') }}

),

final as (

    select
        o.order_id,
        o.customer_id,
        o.order_status,
        o.ordered_at,
        o.updated_at,

        coalesce(oa.item_count, 0)     as item_count,
        coalesce(oa.total_quantity, 0) as total_quantity,
        coalesce(oa.subtotal_cents, 0) as subtotal_cents,
        cast({{ cents_to_dollars('coalesce(oa.subtotal_cents, 0)') }} as numeric(12, 2)) as subtotal,

        coalesce(pp.total_amount_cents, 0) as total_paid_cents,
        cast({{ cents_to_dollars('coalesce(pp.total_amount_cents, 0)') }} as numeric(12, 2)) as total_paid,
        coalesce(pp.has_successful_payment, false) as has_successful_payment,

        pp.credit_card_amount_cents,
        pp.paypal_amount_cents,
        pp.bank_transfer_amount_cents,
        pp.gift_card_amount_cents

    from orders o
    left join order_amounts oa on oa.order_id = o.order_id
    left join payments_pivoted pp on pp.order_id = o.order_id

)

select * from final
