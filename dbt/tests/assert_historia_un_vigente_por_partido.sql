-- Un partido no puede estar vigente (is_current) en más de una versión a la vez.
-- Devuelve los partidos con más de una versión vigente; si devuelve cero, pasa.
select
    partido_key,
    count(*) as vigentes
from {{ ref('partidos_historia') }}
where is_current
group by partido_key
having count(*) > 1
