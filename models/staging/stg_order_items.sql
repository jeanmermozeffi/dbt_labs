-- Modele de staging : lignes de commande

with source as (

    select * from {{ source('raw', 'order_items') }}

),

renamed as (

    select
        order_item_id,
        order_id,
        product_id,
        quantity,
        unit_price_cents,
        {{ cents_to_dollars('unit_price_cents') }} as unit_price,
        quantity * unit_price_cents as line_amount_cents,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
