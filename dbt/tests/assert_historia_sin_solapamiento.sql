-- Dos versiones del mismo partido no pueden solaparse en el tiempo (intervalos
-- cerrados). Devuelve los pares que se pisan; si devuelve cero filas, pasa.
select
    a.partido_key,
    a.valid_from as a_from,
    a.valid_to   as a_to,
    b.valid_from as b_from,
    b.valid_to   as b_to
from {{ ref('partidos_historia') }} a
join {{ ref('partidos_historia') }} b
    on  a.partido_key = b.partido_key
    and a.valid_from  < b.valid_from      -- pares ordenados, sin auto-comparar
    and b.valid_from <= a.valid_to        -- b arranca dentro del rango de a
