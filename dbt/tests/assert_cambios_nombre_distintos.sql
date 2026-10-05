-- Todo registro de int_cambios_nombre debe tener nombres distintos.
-- Devuelve las filas donde el nombre no cambió; si devuelve cero filas, el test pasa.
select *
from {{ ref('int_cambios_nombre') }}
where nombre_anterior = nombre_nuevo
