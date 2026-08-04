-- Modele de staging : commandes

with source as (

    select * from {{ source('raw', 'orders') }}

),

renamed as (

    select
        order_id,
        customer_id,
        order_status,
        ordered_at,
        updated_at,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
