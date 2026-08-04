-- Modele de staging : produits

with source as (

    select * from {{ source('raw', 'products') }}

),

renamed as (

    select
        product_id,
        product_name,
        category,
        unit_price_cents,
        {{ cents_to_dollars('unit_price_cents') }} as unit_price,
        case
            when {{ cents_to_dollars('unit_price_cents') }} < 30 then 'budget'
            when {{ cents_to_dollars('unit_price_cents') }} < 80 then 'mid'
            else 'premium'
        end as price_tier,
        is_active,
        created_at,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
