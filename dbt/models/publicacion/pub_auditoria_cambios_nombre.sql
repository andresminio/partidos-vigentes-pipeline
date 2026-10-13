-- Capa de PRESENTACIÓN de la auditoría de cambios de nombre para la segunda hoja
-- del Sheet "Cambios de nombre". El formato vive acá (no en el Apps Script):
-- cierre dd-mm-aaaa y el orden de filas (orden_fila).
--
-- Orden:
--   1. Nacionales, por número de partido.
--   2. Distritos, por número de distrito y después número de partido.
--   Dentro de cada partido, por cierre: se lee su historia de corrido.

with a as (

    select * from {{ ref('auditoria_cambios_nombre') }}

)

select
    -- Orden de filas (se usa para ordenar; el volcador la excluye de la salida).
    row_number() over (
        order by
            case when orden = 'NACIONAL' then 1 else 2 end,
            case when orden = 'NACIONAL' then cast(nro_partido as int64) end,
            cast(nro_distrito as int64),
            cast(nro_partido  as int64),
            cierre
    ) as orden_fila,

    partido_key as idpartido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    format_date('%d-%m-%Y', cierre) as cierre,
    nombre_anterior,
    nombre_crudo,
    nombre_final,
    motivo

from a
