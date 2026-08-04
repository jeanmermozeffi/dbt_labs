-- Analyse ad hoc (dossier `analyses/`) : jamais materialisee en base,
-- juste compilee. Utile pour des requetes exploratoires versionnees
-- dans git sans polluer le DAG de modeles.
--   dbt compile --select revenue_by_country
--   -> SQL final dans target/compiled/dbt_labs/analyses/revenue_by_country.sql

select
    country_name,
    count(distinct customer_id) as customers,
    sum(lifetime_value_cents) as revenue_cents,
    {{ pretty_currency('sum(lifetime_value_cents)') }} as revenue_formatted
from {{ ref('dim_customers') }}
group by country_name
order by revenue_cents desc
