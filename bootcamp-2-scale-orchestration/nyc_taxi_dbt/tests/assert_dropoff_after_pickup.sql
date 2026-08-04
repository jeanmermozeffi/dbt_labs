-- Test singulier : un trajet ne peut pas se terminer avant d'avoir commence.
select
    pickup_at,
    dropoff_at
from {{ ref('fct_trips') }}
where dropoff_at < pickup_at
