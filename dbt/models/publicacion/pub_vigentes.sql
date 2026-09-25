-- Capa de PRESENTACIÓN de la foto actual (partidos vigentes) para el Sheet.
-- Fechas dd-mm-aaaa; orden por distrito -> orden -> número. El volcador la escribe
-- tal cual (excluyendo orden_fila).

select
    row_number() over (
        order by cast(nro_distrito as int64), orden, cast(nro_partido as int64)
    ) as orden_fila,

    id_partido as idpartido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    partido_politico,
    sigla,
    integra_partido_nacional as integra_nacional,
    format_date('%d-%m-%Y', fecha_reconocimiento) as fecha_reconocimiento,
    format_date('%d-%m-%Y', Cierre)               as fecha_cierre,
    Actualizado                                   as actualizado

from {{ ref('partidos_vigentes') }}
