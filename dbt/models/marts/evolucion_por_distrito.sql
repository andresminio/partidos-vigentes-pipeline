{{ config(materialized='table') }}

-- Cantidad de partidos por distrito y por mes. Se apoya en int_partidos
-- (datos por snapshot, ya limpios). Un partido NACIONAL cuenta en su distrito sede.

with base as (

    select snapshot_date, orden, nro_distrito, distrito
    from {{ ref('int_partidos') }}

)

select
    snapshot_date,
    extract(year from snapshot_date) as anio,
    format_date('%m', snapshot_date) as mes,
    nro_distrito,
    distrito,
    countif(orden = 'NACIONAL') as nacionales,
    countif(orden = 'DISTRITO') as distritales,
    count(*)                    as total
from base
group by snapshot_date, nro_distrito, distrito
order by snapshot_date, nro_distrito
