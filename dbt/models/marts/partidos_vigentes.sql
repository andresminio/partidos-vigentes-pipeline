{{ config(materialized='table') }}

-- Foto actual del Registro: los partidos vigentes en el último snapshot cargado.
-- Se apoya en el SCD2 (partidos_historia), filtrando la versión vigente.

select
    partido_key as id_partido,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    partido_politico,
    sigla,
    fecha_reconocimiento,
    case when integra_partido_nacional then 'SI' else 'NO' end as integra_partido_nacional,
    valid_to as Cierre,                            -- fecha del cierre (snapshot del que proviene esta foto)
    {{ actualizado('_ingested_at') }} as Actualizado   -- cuándo se procesó este cierre (hora Argentina)
from {{ ref('partidos_historia') }}
where is_current
