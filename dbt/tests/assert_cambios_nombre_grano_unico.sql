-- Grano de partidos_cambios_nombre: un solo cambio por partido y cierre.
-- Devuelve las combinaciones repetidas; si devuelve cero filas, el test pasa.
select
    partido_key,
    fecha_cambio_nombre,
    count(*) as n
from {{ ref('partidos_cambios_nombre') }}
group by partido_key, fecha_cambio_nombre
having count(*) > 1
