{{ config(materialized='table') }}

-- AUDITORÍA de cambios de nombre: TODOS los cambios, por cualquier motivo, con la
-- trazabilidad de qué vino del raw y qué hizo el procesamiento.
-- Grano: partido x cierre en que cambió el nombre CRUDO (tal cual el Excel) o el
-- nombre FINAL (después de todo el procesamiento) respecto de la aparición
-- anterior del partido.
--
-- resolucion:
--   Si el nombre final NO cambió (el procesamiento absorbió el cambio del crudo),
--   el mecanismo más específico que actuó en alguno de los dos cierres:
--     ERROR_CARGA > EQUIVALENCIA > HEREDADO_NACIONAL
--     > LIMPIEZA_FORMATO > NORMALIZACION
--   Si el nombre final SÍ cambió, el estado de la validación humana:
--     ACEPTADO / HEREDADO_ACEPTADO (está en partidos_cambios_nombre) o PENDIENTE.

with base as (

    select
        partido_key,
        snapshot_date,
        orden,
        nro_distrito,
        distrito,
        nro_partido,
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
        nombre_crudo is distinct from crudo_anterior as cambio_en_crudo,
        nombre_final is distinct from final_anterior as cambio_en_final
    from con_anterior
    where fecha_anterior is not null
      and (nombre_crudo is distinct from crudo_anterior
           or nombre_final is distinct from final_anterior)

),

curados as (

    select partido_key, fecha_cambio_nombre, decision_heredada_de
    from {{ ref('partidos_cambios_nombre') }}

),

{% set prioridad %}
    case {m}
        when 'ERROR_CARGA'        then 1
        when 'EQUIVALENCIA'       then 3
        when 'HEREDADO_NACIONAL'  then 4
        when 'LIMPIEZA_FORMATO'   then 5
        when 'NORMALIZACION'      then 6
        else 99
    end
{% endset %}

resuelto as (

    select
        e.*,
        case
            when e.cambio_en_final and c.partido_key is not null
                then if(c.decision_heredada_de is null, 'ACEPTADO', 'HEREDADO_ACEPTADO')
            when e.cambio_en_final
                then 'PENDIENTE'
            when {{ prioridad.replace('{m}', 'e.motivo_nombre') }}
                 <= {{ prioridad.replace('{m}', 'e.motivo_anterior') }}
                then coalesce(e.motivo_nombre, e.motivo_anterior)
            else coalesce(e.motivo_anterior, e.motivo_nombre)
        end as resolucion
    from eventos e
    left join curados c
        on  c.partido_key         = e.partido_key
        and c.fecha_cambio_nombre = e.snapshot_date

)

select
    partido_key,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    fecha_anterior,
    snapshot_date  as fecha_cambio,
    crudo_anterior,
    nombre_crudo   as crudo_nuevo,
    final_anterior,
    nombre_final   as final_nuevo,
    cambio_en_crudo,
    cambio_en_final,
    motivo_anterior,
    motivo_nombre  as motivo_nuevo,
    coalesce(resolucion, 'SIN_MOTIVO') as resolucion
from resuelto
