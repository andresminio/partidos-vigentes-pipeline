-- Un cambio marcado como ERROR_CARGA debería desaparecer de int_cambios_nombre
-- una vez aplicada la corrección en staging. Si sigue apareciendo, la corrección
-- no alcanzó (p.ej. la regla del nombre del nacional en int_partidos vuelve a
-- generar la diferencia): hay que revisarlo.
-- severity='warn': se reporta en cada cierre sin frenar el pipeline.
{{ config(severity='warn') }}

select h.*
from {{ ref('stg_decisiones_cambios_nombre') }} h
join {{ ref('int_cambios_nombre') }} c
    on  c.partido_key         = h.partido_key
    and c.fecha_cambio_nombre = h.fecha_cambio_nombre
    and c.nombre_anterior     = h.nombre_anterior
    and c.nombre_nuevo        = h.nombre_nuevo
where h.decision = 'ERROR_CARGA'
