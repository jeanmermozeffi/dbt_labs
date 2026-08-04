#!/usr/bin/env python3
"""
Genere un jeu de donnees synthetique "yellow taxi", au MEME schema que
les vrais fichiers NYC TLC (colonnes, types, ordres de grandeur), pour
que le bootcamp reste 100% reproductible sans dependre de la
disponibilite d'un CDN externe.

Le module 02 du bootcamp documente, avec des chiffres reels captures
en conditions reelles, comment brancher ce meme projet sur les vrais
fichiers publics NYC TLC (https://d37ci6vzurychx.cloudfront.net/trip-data/)
via read_parquet() a distance -- cette technique n'a besoin d'aucune
modification du projet dbt, seulement de la source du glob de fichiers.

Ecrit dans data/raw_parquet/pickup_year=YYYY/pickup_month=MM/trips.parquet
(partitionnement Hive) et data/raw_seeds/taxi_zone_lookup.csv.

Usage :
    .venv/bin/python scripts/generate_synthetic_trips.py
"""
import time
from pathlib import Path

import duckdb

ROOT = Path(__file__).resolve().parent.parent
RAW_PARQUET_DIR = ROOT / "data" / "raw_parquet"
ZONES_PATH = ROOT / "data" / "raw_seeds" / "taxi_zone_lookup.csv"

ROWS_PER_MONTH = 8_000_000
MONTHS = [(2019, 1, 31), (2019, 2, 28), (2019, 3, 31)]
N_ZONES = 50

con = duckdb.connect()
con.execute("select setseed(0.42);")

# ---------------------------------------------------------------------
# Zones (seed de reference, structure inspiree de taxi_zone_lookup.csv,
# donnees ILLUSTRATIVES -- ce ne sont pas les vraies zones NYC TLC)
# ---------------------------------------------------------------------
ZONES_PATH.parent.mkdir(parents=True, exist_ok=True)
con.execute(f"""
    copy (
        select
            i as "LocationID",
            (array['Manhattan', 'Brooklyn', 'Queens', 'Bronx', 'Staten Island'])[1 + (i % 5)] as "Borough",
            'Zone ' || i as "Zone",
            case when i % 9 = 0 then 'Airports' else 'Boro Zone' end as "service_zone"
        from range(1, {N_ZONES + 1}) as t(i)
    ) to '{ZONES_PATH}' (header, delimiter ',')
""")
print(f"zones -> {ZONES_PATH}")

# ---------------------------------------------------------------------
# Trips, un fichier parquet par mois, partitionnement Hive sur disque
# ---------------------------------------------------------------------
for year, month, days_in_month in MONTHS:
    t0 = time.time()
    out_dir = RAW_PARQUET_DIR / f"pickup_year={year}" / f"pickup_month={month:02d}"
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "trips.parquet"

    con.execute(f"""
        copy (
            with base as (
                select
                    1 + (random() > 0.5)::int as vendor_id,
                    timestamp '{year}-{month:02d}-01'
                        + (random() * {days_in_month} * 86400)::bigint * interval '1 second'
                        as pickup_ts,
                    (2 + power(random(), 2) * 58) as duration_minutes,
                    case
                        when random() < 0.70 then 1
                        when random() < 0.90 then 2
                        when random() < 0.97 then 3
                        else 4 + (random() * 2)::int
                    end as passenger_count,
                    round((-ln(1 - random()) * 3)::numeric, 2) as trip_distance,
                    case
                        when random() < 0.95 then 1
                        when random() < 0.98 then 2
                        else 3 + (random() * 3)::int
                    end as ratecode_id,
                    case when random() < 0.005 then 'Y' else 'N' end as store_and_fwd_flag,
                    (1 + (random() * {N_ZONES - 1})::int) as pu_location_id,
                    (1 + (random() * {N_ZONES - 1})::int) as do_location_id,
                    case
                        when random() < 0.65 then 1
                        when random() < 0.95 then 2
                        when random() < 0.98 then 3
                        else 4
                    end as payment_type,
                    random() as tip_roll,
                    random() as toll_roll
                from range({ROWS_PER_MONTH}) as t(i)
            ),
            priced as (
                select
                    *,
                    round((2.5 + trip_distance * 2.5 + duration_minutes * 0.35)::numeric, 2) as fare_amount,
                    case when pu_location_id <= 10 then 2.50 else 0.00 end as congestion_surcharge,
                    case when toll_roll < 0.05 then round((5 + random() * 5)::numeric, 2) else 0.00 end as tolls_amount
                from base
            )

            select
                vendor_id as "VendorID",
                pickup_ts as tpep_pickup_datetime,
                pickup_ts + (duration_minutes * 60)::bigint * interval '1 second' as tpep_dropoff_datetime,
                passenger_count,
                trip_distance,
                ratecode_id as "RatecodeID",
                store_and_fwd_flag,
                pu_location_id as "PULocationID",
                do_location_id as "DOLocationID",
                payment_type,
                fare_amount,
                0.50 as extra,
                0.50 as mta_tax,
                case
                    when payment_type = 1 and tip_roll < 0.6
                    then round((fare_amount * (0.1 + tip_roll * 0.2))::numeric, 2)
                    else 0.00
                end as tip_amount,
                tolls_amount,
                0.30 as improvement_surcharge,
                congestion_surcharge,
                round((
                    fare_amount + 0.50 + 0.50
                    + case when payment_type = 1 and tip_roll < 0.6
                           then round((fare_amount * (0.1 + tip_roll * 0.2))::numeric, 2)
                           else 0.00 end
                    + tolls_amount + 0.30 + congestion_surcharge
                )::numeric, 2) as total_amount
            from priced
        ) to '{out_path}' (format parquet)
    """)

    elapsed = time.time() - t0
    size_mb = out_path.stat().st_size / 1_000_000
    print(f"{year}-{month:02d}: {ROWS_PER_MONTH:,} lignes -> {out_path} ({size_mb:.1f} MB, {elapsed:.1f}s)")

print("Termine.")
