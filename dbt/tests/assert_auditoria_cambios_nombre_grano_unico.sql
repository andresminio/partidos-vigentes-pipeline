-- Grano de auditoria_cambios_nombre: una fila por partido y cierre.
-- Devuelve las combinaciones repetidas; si devuelve cero filas, el test pasa.
select
    partido_key,
    fecha_cambio,
    count(*) as n
from {{ ref('auditoria_cambios_nombre') }}
group by partido_key, fecha_cambio
having count(*) > 1
