-- Capa de PRESENTACIÓN de la historización para la hoja "Historización" del Sheet.
-- Todo el formato de publicación vive acá (no en el Apps Script): nombres finales,
-- SI/NO, fechas dd-mm-aaaa, "cierre actual" en la vigencia abierta y el orden de
-- filas (orden_fila). El Apps Script solo vuelca esta vista tal cual, así que
-- cambiar la presentación no requiere re-desplegar el web app.

with h as (

    select * from {{ ref('partidos_historia') }}

)

select
    -- Orden de filas (se usa para ordenar; el volcador la excluye de la salida).
    row_number() over (
        order by
            cast(nro_distrito as int64),
            cast(nro_partido  as int64),
            orden desc,              -- NACIONAL antes que DISTRITO
            valid_from
    ) as orden_fila,

    partido_key as idpartido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    partido_politico,
    sigla,
    case when integra_partido_nacional then 'SI' else 'NO' end as integra_nacional,

    -- fecha_reconocimiento queda justo antes de disponible_desde.
    format_date('%d-%m-%Y', fecha_reconocimiento) as fecha_reconocimiento,
    format_date('%d-%m-%Y', valid_from)           as disponible_desde,

    -- La vigencia abierta (último cierre) muestra "cierre actual" en vez de fecha.
    case when is_current then 'cierre actual'
         else format_date('%d-%m-%Y', valid_to) end as disponible_hasta,

    case when is_current then 'SI' else 'NO' end     as ultimo_cierre

from h
