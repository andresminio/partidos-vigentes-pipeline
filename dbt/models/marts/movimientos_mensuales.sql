{{ config(materialized='table') }}

-- Altas y bajas por mes, derivadas del SCD2.
--   Alta: una versión que empieza (valid_from = ese mes). Se excluye el primer
--         snapshot: ahí "aparecen" todos, pero es la carga inicial, no altas reales.
--   Baja: una versión cerrada (no vigente) deja de estar presente. La baja se
--         registra en el snapshot SIGUIENTE a su valid_to (primer mes de ausencia).
-- Nota: con estos datos no se distingue "caducidad" de otras bajas (la fuente no
-- trae el motivo); una baja = desaparición del listado de vigentes.

with historia as (

    select * from {{ ref('partidos_historia') }}

),

-- Secuencia de todos los snapshots cargados (para ubicar el mes siguiente a una baja
-- y para excluir el primer snapshot de las altas).
calendario as (

    select
        snapshot_date,
        dense_rank() over (order by snapshot_date) as periodo
    from (select distinct snapshot_date from {{ ref('int_partidos') }})

),

-- Altas: versiones que empiezan, salvo en el primer snapshot (carga inicial).
altas as (

    select
        h.valid_from as snapshot_date,
        count(*)     as altas
    from historia h
    join calendario c on c.snapshot_date = h.valid_from
    where c.periodo > 1
    group by h.valid_from

),

-- Bajas: versiones cerradas -> baja en el snapshot siguiente a valid_to.
bajas as (

    select
        sig.snapshot_date as snapshot_date,
        count(*)          as bajas
    from historia h
    join calendario c_to  on c_to.snapshot_date = h.valid_to
    join calendario sig   on sig.periodo = c_to.periodo + 1
    where not h.is_current
    group by sig.snapshot_date

),

final as (

    select
        c.snapshot_date,
        extract(year from c.snapshot_date) as anio,
        format_date('%m', c.snapshot_date) as mes,
        coalesce(a.altas, 0) as altas,
        coalesce(b.bajas, 0) as bajas,
        coalesce(a.altas, 0) - coalesce(b.bajas, 0) as neto
    from calendario c
    left join altas a using (snapshot_date)
    left join bajas b using (snapshot_date)

)

select * from final
order by snapshot_date
