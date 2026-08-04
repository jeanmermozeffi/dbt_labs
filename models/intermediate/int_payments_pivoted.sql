-- Couche intermediaire : pivot des paiements par moyen de paiement,
-- au grain "commande". Pattern canonique dbt (popularise par le
-- tutoriel jaffle_shop) : dbt_utils.pivot + une macro qui va chercher
-- dynamiquement les valeurs distinctes a pivoter.

with payments as (

    select * from {{ ref('stg_payments') }}

),

pivoted as (

    select
        order_id,
        {{ dbt_utils.pivot(
            column='payment_method',
            values=get_payment_methods(),
            then_value='amount_cents',
            else_value=0,
            suffix='_amount_cents'
        ) }},
        sum(amount_cents) as total_amount_cents,
        bool_or(payment_status = 'success') as has_successful_payment

    from payments
    group by order_id

)

select * from pivoted
