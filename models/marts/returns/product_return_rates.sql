{{ config(materialized='table') }}

-- Mart du domaine "returns" (groupe dbt distinct de "core", voir
-- models/groups.yml et bootcamp/10-gouvernance-multi-projets).
-- Grain = 1 ligne par produit. Sous contrat de donnees (bootcamp/07).

with order_items as (

    select * from {{ ref('fct_order_items') }}

),

returns as (

    select * from {{ ref('fct_returns') }}

),

items_with_returns as (

    select
        oi.product_id,
        oi.order_item_id,
        oi.line_amount_cents,
        case when r.return_id is not null then 1 else 0 end as is_returned,
        coalesce(r.refund_amount_cents, 0) as refund_amount_cents

    from order_items oi
    left join returns r on r.order_item_id = oi.order_item_id

),

aggregated as (

    select
        product_id,
        count(*) as items_sold,
        sum(is_returned) as items_returned,
        round(sum(is_returned)::numeric / nullif(count(*), 0), 4) as return_rate,
        sum(refund_amount_cents) as refunded_amount_cents

    from items_with_returns
    group by product_id

),

final as (

    select
        p.product_id,
        p.product_name,
        p.category,
        coalesce(a.items_sold, 0) as items_sold,
        coalesce(a.items_returned, 0) as items_returned,
        cast(coalesce(a.return_rate, 0) as numeric(6, 4)) as return_rate,
        coalesce(a.refunded_amount_cents, 0) as refunded_amount_cents,
        cast({{ cents_to_dollars('coalesce(a.refunded_amount_cents, 0)') }} as numeric(12, 2)) as refunded_amount

    from {{ ref('dim_products') }} p
    left join aggregated a on a.product_id = p.product_id

)

select * from final
