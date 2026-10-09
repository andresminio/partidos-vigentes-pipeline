{{ config(materialized='table') }}

-- Cambios de nombre CURADOS: solo los cambios detectados (int_cambios_nombre)
-- que pasaron la validación humana.
--   - Directos: el cambio fue ACEPTADO en la validación (decisiones_cambios_nombre)
--     (coinciden partido_key, fecha_cambio_nombre y ambos nombres).
--   - Heredados: un cambio HEREDADO_NACIONAL de un partido de distrito se acepta
--     si está aceptado el cambio del nacional que integra (mismo nro_partido,
--     misma fecha de cambio y mismo nombre nuevo). Hereda su decisión y fundamento.
-- Los cambios sin decisión quedan fuera y se listan en el test
-- warn_cambios_nombre_pendientes. Los errores de carga no llegan acá: se
-- corrigen en staging (ERROR_CARGA) y dejan de detectarse.

with cambios as (

    select * from {{ ref('int_cambios_nombre') }}

),

homologacion as (

    select
        partido_key,
        fecha_cambio_nombre,
        nombre_anterior,
        nombre_nuevo,
        decision,
        date(decidido_en, 'America/Argentina/Buenos_Aires') as fecha_decision,
        fundamento,
        decidido_por as revisado_por
    from {{ ref('stg_decisiones_cambios_nombre') }}
    where decision = 'ACEPTADO'

),

directos as (

    select
        c.partido_key,
        c.orden,
        c.nro_distrito,
        c.distrito,
        c.nro_partido,
        c.nombre_anterior,
        c.nombre_anterior_desde,
        c.nombre_anterior_hasta,
        c.nombre_nuevo,
        c.fecha_cambio_nombre,
        c.distancia_edicion,
        c.tipo_cambio,
        c.origen_cambio,
        h.decision,
        h.fecha_decision,
        h.fundamento,
        h.revisado_por,
        cast(null as string) as decision_heredada_de
    from cambios c
    join homologacion h
        on  h.partido_key         = c.partido_key
        and h.fecha_cambio_nombre = c.fecha_cambio_nombre
        and h.nombre_anterior     = c.nombre_anterior
        and h.nombre_nuevo        = c.nombre_nuevo

),

nacionales_aceptados as (

    select * from directos where orden = 'NACIONAL'

),

heredados as (

    select
        c.partido_key,
        c.orden,
        c.nro_distrito,
        c.distrito,
        c.nro_partido,
        c.nombre_anterior,
        c.nombre_anterior_desde,
        c.nombre_anterior_hasta,
        c.nombre_nuevo,
        c.fecha_cambio_nombre,
        c.distancia_edicion,
        c.tipo_cambio,
        c.origen_cambio,
        n.decision,
        n.fecha_decision,
        n.fundamento,
        n.revisado_por,
        n.partido_key as decision_heredada_de
    from cambios c
    join nacionales_aceptados n
        on  n.nro_partido         = c.nro_partido
        and n.fecha_cambio_nombre = c.fecha_cambio_nombre
        and n.nombre_nuevo        = c.nombre_nuevo
    where c.origen_cambio = 'HEREDADO_NACIONAL'
      and c.orden = 'DISTRITO'
      -- si el cambio ya fue aceptado en forma directa, no se duplica
      and not exists (
          select 1 from directos d
          where d.partido_key = c.partido_key
            and d.fecha_cambio_nombre = c.fecha_cambio_nombre
      )

)

select * from directos
union all
select * from heredados
