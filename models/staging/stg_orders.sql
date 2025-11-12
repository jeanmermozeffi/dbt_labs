-- Modèle de staging pour les commandes
-- Ce modèle nettoie et standardise les données brutes des commandes

with source as (
    select * from {{ source('raw', 'orders') }}
),

renamed as (
    select
        id as order_id,
        customer_id,
        order_date,
        amount as order_amount,
        current_timestamp() as loaded_at
    from source
)

select * from renamed
