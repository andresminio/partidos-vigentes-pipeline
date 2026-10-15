-- Capa de PRESENTACIÓN de los cambios de nombre CURADOS (solo aceptados) para la hoja "Cambios de nombre"
-- del Sheet. Todo el formato de publicación vive acá (no en el Apps Script):
-- nombres finales, fechas dd-mm-aaaa y el orden de filas (orden_fila). El Apps
-- Script solo vuelca esta vista tal cual, así que cambiar la presentación no
-- requiere re-desplegar el web app.
--
-- Orden en dos bloques, según el ORIGEN del cambio:
--   1. Cambios del nacional: los nacionales y los distritos que heredan su cambio
--      (origen_cambio = CAMBIO_NACIONAL). Por número de partido, el nacional
--      primero, después sus distritos (por número de distrito) y por fecha.
--   2. Cambios distritales propios (origen_cambio = PROPIO), integren o no un
--      nacional: por número de distrito, número de partido y fecha.
-- integra_nacional (SI/NO) se toma del cierre en que se produjo el cambio.

with c as (

    select * from {{ ref('partidos_cambios_nombre') }}

),

integra as (

    select partido_key, snapshot_date, integra_partido_nacional
    from {{ ref('int_partidos') }}

),

base as (

    select
        c.*,
        i.integra_partido_nacional,
        case
            when c.orden = 'NACIONAL'                 then 1
            when c.origen_cambio = 'CAMBIO_NACIONAL'  then 1
            else 2
        end as bloque
    from c
    left join integra i
        on  i.partido_key   = c.partido_key
        and i.snapshot_date = c.fecha_cambio_nombre

)

select
    -- Orden de filas (se usa para ordenar; el volcador la excluye de la salida).
    row_number() over (
        order by
            bloque,
            -- bloque 1: por número de partido, NACIONAL antes que DISTRITO
            case when bloque = 1 then cast(nro_partido as int64) end,
            case when bloque = 1 then orden end desc,
            -- ambos bloques: por distrito, número y fecha
            cast(nro_distrito as int64),
            cast(nro_partido  as int64),
            fecha_cambio_nombre
    ) as orden_fila,

    partido_key as idpartido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    case when integra_partido_nacional then 'SI' else 'NO' end as integra_nacional,
    nombre_anterior,
    format_date('%d-%m-%Y', nombre_anterior_desde) as nombre_anterior_desde,
    format_date('%d-%m-%Y', nombre_anterior_hasta) as nombre_anterior_hasta,
    nombre_nuevo,
    format_date('%d-%m-%Y', fecha_cambio_nombre)   as fecha_cambio_nombre,
    origen_cambio

from base
