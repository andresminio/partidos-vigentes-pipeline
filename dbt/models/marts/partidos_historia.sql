{{ config(materialized='table') }}

-- Historización SCD2 por VIGENCIA: una fila por cada tramo continuo en que un
-- partido estuvo presente en los snapshots. La versión se corta por baja/realta
-- (ausencia en un snapshot que existe), no por cambios de atributos.

with base as (

    select
        partido_key,
        snapshot_date,
        orden,
        nro_distrito,
        distrito,
        nro_partido,
        partido_politico,
        sigla,
        fecha_reconocimiento,
        integra_partido_nacional
    from {{ ref('int_partidos') }}

),

-- Secuencia de snapshots realmente cargados (no meses del calendario).
-- Un mes sin cierre no genera baja: p.ej. si falta enero, febrero sigue a diciembre.
calendario as (

    select
        snapshot_date,
        dense_rank() over (order by snapshot_date) as periodo
    from (select distinct snapshot_date from base)

),

con_periodo as (

    select
        b.*,
        c.periodo,
        lag(c.periodo) over (
            partition by b.partido_key order by c.periodo
        ) as periodo_previo
    from base b
    join calendario c using (snapshot_date)

),

-- Marca el inicio de una versión: primera aparición, o hueco en la secuencia
-- (el partido faltó en uno o más snapshots que sí existen -> baja y realta).
marcado as (

    select
        *,
        case
            when periodo_previo is null then 1
            when periodo - periodo_previo > 1 then 1
            else 0
        end as es_nueva_version
    from con_periodo

),

-- Suma acumulada de las marcas: convierte los tramos en un id de versión por partido.
versionado as (

    select
        *,
        sum(es_nueva_version) over (
            partition by partido_key order by periodo
        ) as version_id
    from marcado

),

-- Una fila por versión, con los atributos del ÚLTIMO snapshot de esa versión
-- (los más recientes) y el rango de la versión.
versiones as (

    select
        partido_key,
        version_id,
        min(snapshot_date) over (partition by partido_key, version_id) as valid_from,
        max(snapshot_date) over (partition by partido_key, version_id) as valid_to,
        max(periodo)       over (partition by partido_key, version_id) as ultimo_periodo,
        orden,
        nro_distrito,
        distrito,
        nro_partido,
        partido_politico,
        sigla,
        fecha_reconocimiento,
        integra_partido_nacional
    from versionado
    qualify row_number() over (
        partition by partido_key, version_id order by periodo desc
    ) = 1

),

-- Intervalo cerrado: valid_from y valid_to son el primer y el último snapshot
-- en que aparece la versión (ambos son meses reales observados). is_current:
-- la versión llega hasta el último snapshot cargado -> el partido sigue vigente.
final as (

    select
        v.partido_key,
        v.orden,
        v.nro_distrito,
        v.distrito,
        v.nro_partido,
        v.partido_politico,
        v.sigla,
        v.fecha_reconocimiento,
        v.integra_partido_nacional,
        v.valid_from,
        v.valid_to,
        (v.ultimo_periodo = (select max(periodo) from calendario)) as is_current
    from versiones v

)

select * from final
