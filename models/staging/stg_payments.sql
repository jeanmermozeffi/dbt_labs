-- Modele de staging : paiements

with source as (

    select * from {{ source('raw', 'payments') }}

),

renamed as (

    select
        payment_id,
        order_id,
        payment_method,
        payment_status,
        amount_cents,
        {{ cents_to_dollars('amount_cents') }} as amount,
        paid_at,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
