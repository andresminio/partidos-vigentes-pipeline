{{ config(materialized='table') }}

-- Foto actual del padrón: los partidos vigentes en el último snapshot cargado.
-- Se apoya en el SCD2 (partidos_historia), filtrando la versión vigente.

select
    partido_key,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    partido_politico,
    sigla,
    fecha_reconocimiento,
    integra_partido_nacional,
    valid_from as vigente_desde   -- desde cuándo está vigente de forma continua
from {{ ref('partidos_historia') }}
where is_current
