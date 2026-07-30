-- Cada versión debe tener un rango bien formado: valid_from <= valid_to.
-- Devuelve las versiones con el rango invertido; si devuelve cero filas, pasa.
select
    partido_key,
    valid_from,
    valid_to
from {{ ref('partidos_historia') }}
where valid_from > valid_to
