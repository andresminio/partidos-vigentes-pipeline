{{ config(materialized='table') }}

-- AUDITORÍA de cambios de nombre: todos los cambios, por cualquier motivo, para
-- separar lo que trajo el Excel (nombre crudo) de lo que hizo el procesamiento
-- (nombre final). Se construye sobre cada cierre (int_partidos), no sobre el SCD2:
-- una fila por partido y cierre en que cambió el nombre crudo o el final respecto
-- de la aparición anterior del partido.
--
-- motivo:
--   Si el nombre final cambió:
--     HEREDADO_NACIONAL  el cambio viene del nacional que integra (sin validación)
--     CAMBIO_ACEPTADO    cambio real homologado en la validación
--     PENDIENTE          cambio detectado todavía sin decisión
--   Si el nombre final no cambió (el procesamiento absorbió el cambio del crudo),
--   el mecanismo más específico que actuó en ese cierre o en el anterior:
--     ERROR_RECHAZADO > EQUIVALENCIA > HEREDADO_NACIONAL > FORMATO_NORMALIZACION

with base as (

    select
        partido_key,
        snapshot_date,
        orden,
        nro_distrito,
        distrito,
        nombre_crudo,
        partido_politico as nombre_final,
        motivo_nombre
    from {{ ref('int_partidos') }}

),

con_anterior as (

    select
        *,
        lag(snapshot_date) over w as fecha_anterior,
        lag(nombre_crudo)  over w as crudo_anterior,
        lag(nombre_final)  over w as final_anterior,
        lag(motivo_nombre) over w as motivo_anterior
    from base
    window w as (partition by partido_key order by snapshot_date)

),

eventos as (

    select
        *,
        nombre_final is distinct from final_anterior as cambio_en_final
    from con_anterior
    where fecha_anterior is not null
      and (nombre_crudo is distinct from crudo_anterior
           or nombre_final is distinct from final_anterior)

),

-- Cambios detectados (para saber si un cambio del nombre final fue heredado).
detectados as (

    select partido_key, fecha_cambio_nombre, origen_cambio
    from {{ ref('int_cambios_nombre') }}

),

-- Cambios homologados en la validación.
aceptados as (

    select partido_key, fecha_cambio_nombre
    from {{ ref('partidos_cambios_nombre') }}

),

{% set prioridad %}
    case {m}
        when 'ERROR_CARGA'       then 1
        when 'EQUIVALENCIA'      then 2
        when 'HEREDADO_NACIONAL' then 3
        when 'FORMATO_NORMALIZACION' then 4
        else 99
    end
{% endset %}

resuelto as (

    select
        e.*,
        case
            -- El nombre final cambió: lo resolvió la herencia o la validación.
            when e.cambio_en_final and d.origen_cambio = 'HEREDADO_NACIONAL'
                then 'HEREDADO_NACIONAL'
            when e.cambio_en_final and a.partido_key is not null
                then 'CAMBIO_ACEPTADO'
            when e.cambio_en_final
                then 'PENDIENTE'
            -- El nombre final no cambió: el mecanismo más específico que actuó.
            when {{ prioridad.replace('{m}', 'e.motivo_nombre') }}
                 <= {{ prioridad.replace('{m}', 'e.motivo_anterior') }}
                then coalesce(e.motivo_nombre, e.motivo_anterior)
            else coalesce(e.motivo_anterior, e.motivo_nombre)
        end as motivo_bruto
    from eventos e
    left join detectados d
        on  d.partido_key         = e.partido_key
        and d.fecha_cambio_nombre = e.snapshot_date
    left join aceptados a
        on  a.partido_key         = e.partido_key
        and a.fecha_cambio_nombre = e.snapshot_date

)

select
    partido_key,
    orden,
    nro_distrito,
    distrito,
    snapshot_date as cierre,
    nombre_crudo,
    nombre_final,
    case motivo_bruto
        when 'ERROR_CARGA' then 'ERROR_RECHAZADO'
        else coalesce(motivo_bruto, 'SIN_MOTIVO')
    end as motivo
from resuelto
order by partido_key, cierre
