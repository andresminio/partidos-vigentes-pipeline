-- La clave es única DENTRO de cada snapshot, no en toda la tabla
-- (se repite mes a mes). Este test devuelve las filas que violan esa regla;
-- si devuelve cero filas, el test pasa.
select
    partido_key,
    snapshot_date,
    count(*) as n
from {{ ref('stg_partidos') }}
group by partido_key, snapshot_date
having count(*) > 1
