{{ config(materialized='table') }}

-- Resumen mensual: cantidad de partidos vigentes por tipo de orden, por mes.
-- Una fila por snapshot (mes-año). Se apoya en int_partidos (datos ya limpios).

with base as (

    select snapshot_date, orden
    from {{ ref('int_partidos') }}

),

resumen as (

    select
        snapshot_date,
        extract(year from snapshot_date) as anio,          -- año como número (ej. 2026)
        format_date('%m', snapshot_date) as mes,           -- mes como texto (ej. '01')
        countif(orden = 'NACIONAL') as nacionales,
        countif(orden = 'DISTRITO') as distritales,
        count(*)                    as total
    from base
    group by snapshot_date

)

select * from resumen
order by snapshot_date
