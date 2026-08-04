-- Dimension client (grain = 1 ligne par client), enrichie de mesures
-- comportementales agregees depuis la table de faits fct_orders.
-- Note d'architecture : dim_customers depend de fct_orders (et non
-- l'inverse). Ce n'est pas une violation du modele en etoile : c'est
-- une "dimension enrichie", un pattern courant pour exposer du LTV /
-- RFM directement sur la dimension. fct_orders, lui, ne depend
-- d'aucun mart -> pas de cycle dans le DAG.

with customers as (

    select * from {{ ref('stg_customers') }}

),

countries as (

    select * from {{ ref('countries') }}

),

customer_orders as (

    select
        customer_id,
        count(*) as lifetime_order_count,
        sum(total_paid_cents) as lifetime_value_cents,
        min(ordered_at) as first_order_at,
        max(ordered_at) as most_recent_order_at

    from {{ ref('fct_orders') }}
    where order_status != 'cancelled'
    group by customer_id

),

final as (

    select
        c.customer_id,
        c.customer_name,
        c.first_name,
        c.last_name,
        c.customer_email,
        c.country_code,
        ctry.country_name,
        c.customer_segment,
        c.created_at as customer_since,

        coalesce(co.lifetime_order_count, 0) as lifetime_order_count,
        coalesce(co.lifetime_value_cents, 0) as lifetime_value_cents,
        {{ cents_to_dollars('coalesce(co.lifetime_value_cents, 0)') }} as lifetime_value,
        co.first_order_at,
        co.most_recent_order_at,

        case
            when co.lifetime_order_count is null then 'never_ordered'
            else 'active'
        end as customer_status

    from customers c
    left join countries ctry on ctry.country_code = c.country_code
    left join customer_orders co on co.customer_id = c.customer_id

)

select * from final
