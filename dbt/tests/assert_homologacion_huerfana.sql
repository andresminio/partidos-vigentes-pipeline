-- Toda decisión ACEPTADO vigente debe corresponder a un cambio detectado en
-- int_cambios_nombre (mismo partido, fecha y ambos nombres). Si aparece, algo
-- cambió por debajo (p.ej. una corrección posterior) y la decisión ya no aplica a
-- lo que se revisó: hay que revisarla de nuevo con validar.py.
-- severity='warn': se reporta en cada cierre sin frenar el pipeline.
{{ config(severity='warn') }}

select h.*
from {{ ref('stg_decisiones_cambios_nombre') }} h
left join {{ ref('int_cambios_nombre') }} c
    on  c.partido_key         = h.partido_key
    and c.fecha_cambio_nombre = h.fecha_cambio_nombre
    and c.nombre_anterior     = h.nombre_anterior
    and c.nombre_nuevo        = h.nombre_nuevo
where h.decision = 'ACEPTADO'
  and c.partido_key is null
