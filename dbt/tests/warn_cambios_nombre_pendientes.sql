-- Cola de validación: cambios de nombre detectados que todavía no tienen decisión
-- (no están aceptados ni heredan una aceptación). severity='warn': se reportan en
-- cada cierre sin frenar el pipeline. Para resolver cada uno:
--   - si es real: fila ACEPTADO en seeds/homologacion_cambios_nombre.csv
--   - si es error de carga: fila en seeds/correcciones_nombre.csv
{{ config(severity='warn') }}

select
    c.partido_key,
    c.fecha_cambio_nombre,
    c.nombre_anterior,
    c.nombre_nuevo,
    c.tipo_cambio,
    c.origen_cambio
from {{ ref('int_cambios_nombre') }} c
left join {{ ref('partidos_cambios_nombre') }} p
    on  p.partido_key         = c.partido_key
    and p.fecha_cambio_nombre = c.fecha_cambio_nombre
where p.partido_key is null
