-- Modèle mart combinant les données clients et commandes
-- Ce modèle crée une vue agrégée des commandes par client

with customers as (
    select * from {{ ref('stg_customers') }}
),

orders as (
    select * from {{ ref('stg_orders') }}
),

customer_orders as (
    select
        c.customer_id,
        c.customer_name,
        c.customer_email,
        count(o.order_id) as total_orders,
        sum(o.order_amount) as total_amount,
        min(o.order_date) as first_order_date,
        max(o.order_date) as last_order_date
    from customers c
    left join orders o on c.customer_id = o.customer_id
    group by c.customer_id, c.customer_name, c.customer_email
)

select * from customer_orders
