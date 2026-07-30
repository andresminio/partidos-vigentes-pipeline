-- Identifica (sin romper el build) los partidos de distrito que integran un
-- nacional del mismo número pero con nombre demasiado distinto para asumir que
-- es una variación de escritura. severity='warn': se reportan para revisión manual.
{{ config(severity='warn') }}

select
    partido_key,
    snapshot_date,
    partido_politico,
    nombre_nacional_sugerido
from {{ ref('int_partidos') }}
where revisar_nombre_nacional
