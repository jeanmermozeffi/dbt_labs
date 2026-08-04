{{ config(event_time='pickup_at') }}

select
    "VendorID"              as vendor_id,
    tpep_pickup_datetime    as pickup_at,
    tpep_dropoff_datetime   as dropoff_at,
    passenger_count,
    trip_distance,
    "RatecodeID"            as rate_code_id,
    store_and_fwd_flag,
    "PULocationID"          as pickup_location_id,
    "DOLocationID"          as dropoff_location_id,
    payment_type,
    fare_amount,
    extra,
    mta_tax,
    tip_amount,
    tolls_amount,
    improvement_surcharge,
    congestion_surcharge,
    total_amount,
    cast(pickup_year as integer) as pickup_year,
    cast(pickup_month as integer) as pickup_month
from {{ source('nyc_tlc', 'yellow_tripdata') }}
