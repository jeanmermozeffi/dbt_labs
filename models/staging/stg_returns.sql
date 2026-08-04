-- Modele de staging : retours produits (module 12 - capstone)

with source as (

    select * from {{ source('raw', 'returns') }}

),

renamed as (

    select
        return_id,
        order_item_id,
        reason,
        refund_amount_cents,
        {{ cents_to_dollars('refund_amount_cents') }} as refund_amount,
        returned_at,
        {{ dbt.current_timestamp() }} as loaded_at

    from source

)

select * from renamed
