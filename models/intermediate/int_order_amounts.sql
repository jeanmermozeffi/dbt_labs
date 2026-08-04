-- Couche intermediaire : agregation des lignes de commande au grain
-- "commande". Ephemeral (voir dbt_project.yml) : jamais materialise
-- seul, toujours inline dans les modeles qui le consomment.

with order_items as (

    select * from {{ ref('stg_order_items') }}

),

aggregated as (

    select
        order_id,
        count(*) as item_count,
        sum(quantity) as total_quantity,
        sum(line_amount_cents) as subtotal_cents

    from order_items
    group by order_id

)

select * from aggregated
