-- Modèle de staging pour les clients
-- Ce modèle nettoie et standardise les données brutes des clients

with source as (
    select * from {{ source('raw', 'customers') }}
),

renamed as (
    select
        id as customer_id,
        name as customer_name,
        email as customer_email,
        current_timestamp() as loaded_at
    from source
)

select * from renamed
