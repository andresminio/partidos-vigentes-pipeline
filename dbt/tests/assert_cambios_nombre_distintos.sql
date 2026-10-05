-- Todo registro de partidos_cambios_nombre debe tener nombres distintos.
-- Devuelve las filas donde el nombre no cambió; si devuelve cero filas, el test pasa.
select *
from {{ ref('partidos_cambios_nombre') }}
where nombre_anterior = nombre_nuevo
