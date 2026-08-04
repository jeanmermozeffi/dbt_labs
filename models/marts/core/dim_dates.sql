{{ config(materialized='table') }}

-- Dimension calendaire generee avec dbt_utils.date_spine (module 04).
-- Bornes pilotees par la variable `date_spine_start_date`
-- (dbt_project.yml), surchargeable via --vars.

with spine as (

    {{ dbt_utils.date_spine(
        datepart="day",
        start_date="cast('" ~ var('date_spine_start_date') ~ "' as date)",
        end_date="cast(current_date + interval '1 year' as date)"
    ) }}

),

final as (

    select
        cast(date_day as date)                  as date_day,
        extract(year from date_day)::int         as year_number,
        extract(quarter from date_day)::int      as quarter_number,
        extract(month from date_day)::int        as month_number,
        trim(to_char(date_day, 'Month'))         as month_name,
        extract(week from date_day)::int         as iso_week_number,
        extract(isodow from date_day)::int       as day_of_week,
        trim(to_char(date_day, 'Day'))           as day_name,
        extract(isodow from date_day) in (6, 7)  as is_weekend

    from spine

)

select * from final
