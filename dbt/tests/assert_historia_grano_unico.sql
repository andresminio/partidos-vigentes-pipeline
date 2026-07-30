-- Grano de la tabla historizada: (partido_key, valid_from) debe ser único.
-- Devuelve las claves de versión repetidas; si devuelve cero filas, pasa.
select
    partido_key,
    valid_from,
    count(*) as n
from {{ ref('partidos_historia') }}
group by partido_key, valid_from
having count(*) > 1
