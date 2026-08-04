-- Dimension produit (grain = 1 ligne par produit), enrichie de
-- mesures de ventes agregees depuis fct_order_items.

with products as (

    select * from {{ ref('stg_products') }}

),

product_sales as (

    select
        product_id,
        count(distinct order_id) as orders_count,
        sum(quantity) as units_sold,
        sum(line_amount_cents) as revenue_cents

    from {{ ref('fct_order_items') }}
    where order_status != 'cancelled'
    group by product_id

),

final as (

    select
        p.product_id,
        p.product_name,
        p.category,
        p.unit_price,
        p.is_active,

        coalesce(ps.orders_count, 0) as orders_count,
        coalesce(ps.units_sold, 0) as units_sold,
        coalesce(ps.revenue_cents, 0) as revenue_cents,
        {{ cents_to_dollars('coalesce(ps.revenue_cents, 0)') }} as revenue

    from products p
    left join product_sales ps on ps.product_id = p.product_id

)

select * from final
