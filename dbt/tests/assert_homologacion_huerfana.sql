-- Toda decisión del seed homologacion_cambios_nombre debe corresponder a un cambio
-- detectado en int_cambios_nombre (mismo partido, fecha y ambos nombres). Si falla,
-- algo cambió por debajo (p.ej. una corrección en origen) y la decisión ya no
-- aplica a lo que se revisó: hay que revisarla de nuevo.
-- Devuelve las decisiones huérfanas; si devuelve cero filas, el test pasa.
select h.*
from {{ ref('homologacion_cambios_nombre') }} h
left join {{ ref('int_cambios_nombre') }} c
    on  c.partido_key         = h.partido_key
    and c.fecha_cambio_nombre = h.fecha_cambio_nombre
    and c.nombre_anterior     = h.nombre_anterior
    and c.nombre_nuevo        = h.nombre_nuevo
where c.partido_key is null
