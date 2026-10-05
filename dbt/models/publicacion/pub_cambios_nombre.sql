-- Capa de PRESENTACIÓN de los cambios de nombre para la hoja "Cambios de nombre"
-- del Sheet. Todo el formato de publicación vive acá (no en el Apps Script):
-- nombres finales, fechas dd-mm-aaaa y el orden de filas (orden_fila). El Apps
-- Script solo vuelca esta vista tal cual, así que cambiar la presentación no
-- requiere re-desplegar el web app.

with c as (

    select * from {{ ref('partidos_cambios_nombre') }}

)

select
    -- Orden de filas (se usa para ordenar; el volcador la excluye de la salida).
    row_number() over (
        order by
            cast(nro_distrito as int64),
            cast(nro_partido  as int64),
            orden desc,              -- NACIONAL antes que DISTRITO
            fecha_cambio_nombre
    ) as orden_fila,

    partido_key as idpartido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    nombre_anterior,
    format_date('%d-%m-%Y', nombre_anterior_desde) as nombre_anterior_desde,
    format_date('%d-%m-%Y', nombre_anterior_hasta) as nombre_anterior_hasta,
    nombre_nuevo,
    format_date('%d-%m-%Y', fecha_cambio_nombre)   as fecha_cambio_nombre,
    distancia_edicion,
    tipo_cambio,
    origen_cambio

from c
