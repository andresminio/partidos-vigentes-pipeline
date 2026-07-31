{{ config(materialized='table') }}

-- Detalle por partido y mes (todos los snapshots). Es el backbone interactivo
-- del tablero: conserva todas las dimensiones filtrables (orden, distrito, integra,
-- partido) y toda la historia. La foto actual es este mart filtrado por is_current.
-- Sale de int_partidos, ya con nombres normalizados, distrito canónico y regla del
-- nacional aplicados; solo expone el detalle completo y agrega la bandera is_current.

with base as (

    select * from {{ ref('int_partidos') }}

),

ultimo as (

    select max(snapshot_date) as snapshot_actual from base

)

select
    b.partido_key,
    b.orden,
    b.nro_distrito,
    b.distrito,
    b.nro_partido,
    b.partido_politico,
    b.sigla,
    b.fecha_reconocimiento,
    b.integra_partido_nacional,
    b.snapshot_date,
    extract(year from b.snapshot_date) as anio,
    format_date('%m', b.snapshot_date) as mes,
    (b.snapshot_date = u.snapshot_actual) as is_current

from base b
cross join ultimo u
