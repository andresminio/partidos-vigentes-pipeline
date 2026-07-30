-- Marca (sin romper el build) los casos donde el nombre de distrito que trae la
-- fuente es groseramente distinto del oficial para ese número -> contradicción
-- número↔nombre (ej. nro 6 con "CAPITAL FEDERAL" cuando el 6 es CHACO).
-- Esos NO se corrigen automáticamente; se reportan para revisión manual.
{{ config(severity='warn') }}

select
    nro_distrito,
    distrito,
    distrito_oficial_sugerido,
    count(*) as n
from {{ ref('stg_partidos') }}
where revisar_distrito
group by nro_distrito, distrito, distrito_oficial_sugerido
