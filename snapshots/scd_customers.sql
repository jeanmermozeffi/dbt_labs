{% snapshot scd_customers %}

{{
    config(
        target_schema='snapshots',
        unique_key='customer_id',
        strategy='timestamp',
        updated_at='updated_at',
        invalidate_hard_deletes=True,
    )
}}

-- On snapshotte la SOURCE brute, pas le modele de staging : on veut
-- l'historique le plus proche possible de la verite operationnelle.
-- Voir bootcamp/06-snapshots-scd pour le scenario complet (mise a jour
-- de raw.customers -> nouvelle version dans ce snapshot).

select * from {{ source('raw', 'customers') }}

{% endsnapshot %}
