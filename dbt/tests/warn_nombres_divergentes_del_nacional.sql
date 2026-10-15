-- Partidos de distrito que integran un nacional (mismo numero) pero figuran con
-- un nombre demasiado distinto al del nacional para asumir que es una variacion
-- de escritura (distancia normalizada > 0.40, ver int_partidos). No se corrigen
-- solos: puede ser un nombre propio legitimo o un error de carga.
--
-- Solo se reportan los casos NUEVOS del ultimo cierre: los que en su aparicion
-- anterior no estaban marcados, o lo estaban con otro nombre. Los ya conocidos
-- (mismo partido, mismo nombre) no se repiten cierre a cierre.
-- severity='warn': se reportan para revision sin frenar el pipeline.
{{ config(severity='warn') }}

with p as (

    select
        partido_key,
        snapshot_date,
        partido_politico,
        nombre_nacional_sugerido,
        revisar_nombre_nacional,
        lag(revisar_nombre_nacional) over w as revisar_anterior,
        lag(partido_politico)        over w as nombre_anterior
    from {{ ref('int_partidos') }}
    window w as (partition by partido_key order by snapshot_date)

)

select
    partido_key,
    snapshot_date,
    partido_politico,
    nombre_nacional_sugerido
from p
where snapshot_date = (select max(snapshot_date) from {{ ref('int_partidos') }})
  and revisar_nombre_nacional
  and not (coalesce(revisar_anterior, false) and nombre_anterior = partido_politico)
