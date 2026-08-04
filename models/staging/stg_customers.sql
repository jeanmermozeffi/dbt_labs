-- Modele de staging : clients
-- Renommage, cast, aucune logique metier (regle de la couche staging).

with source as (

    select * from {{ source('raw', 'customers') }}

),

renamed as (

    select
        customer_id,
        first_name,
        last_name,
        first_name || ' ' || last_name as customer_name,
        lower(email) as customer_email,
        country_code,
        customer_segment,
        created_at,
        updated_at,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
