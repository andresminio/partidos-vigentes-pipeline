{{ config(materialized='table') }}

-- Cambios de nombre por partido: una fila por cada vez que el nombre de un
-- partido_key difiere del de su aparición anterior en los cierres cargados.
-- Registra TODOS los cambios (incluidas idas y vueltas A->B->A).
--
-- Fuente: int_partidos (el nombre que ve el tablero, ya normalizado, corregido
-- por seed y con la regla del nombre del nacional aplicada). Los cambios
-- cosméticos del Excel (espacios, tildes, mayúsculas) no aparecen porque
-- staging ya los absorbe.
--
-- Clasificación:
--   tipo_cambio:   ORTOGRAFICO si la distancia de edición (sin espacios ni
--                  puntuación) es <= 2 letras; SUSTANTIVO si es mayor.
--   origen_cambio: PROPIO si cambió el nombre propio del partido (stg_partidos);
--                  HEREDADO_NACIONAL si el propio no cambió y el cambio viene de
--                  heredar el nombre del nacional (regla de int_partidos).
--
-- Fechas: el cambio real ocurrió en algún momento entre fecha_snapshot_anterior
-- (último cierre con el nombre viejo) y fecha_deteccion (primer cierre con el
-- nombre nuevo). La fuente no informa la fecha exacta.

with nombres_finales as (

    select
        partido_key,
        snapshot_date,
        orden,
        nro_distrito,
        distrito,
        nro_partido,
        partido_politico as nombre
    from {{ ref('int_partidos') }}

),

-- Nombre propio del partido, antes de la regla del nacional.
nombres_propios as (

    select
        partido_key,
        snapshot_date,
        partido_politico as nombre_propio
    from {{ ref('stg_partidos') }}

),

base as (

    select
        f.*,
        p.nombre_propio
    from nombres_finales f
    left join nombres_propios p using (partido_key, snapshot_date)

),

-- Compara cada aparición con la anterior del mismo partido. Si el partido faltó
-- en algún cierre, se compara contra su última aparición.
con_anterior as (

    select
        *,
        lag(nombre)        over w as nombre_anterior,
        lag(nombre_propio) over w as nombre_propio_anterior,
        lag(snapshot_date) over w as fecha_snapshot_anterior
    from base
    window w as (partition by partido_key order by snapshot_date)

),

cambios as (

    select
        *,
        -- Distancia de edición sobre el nombre sin espacios ni puntuación, para que
        -- "P.A.I.S" vs "PAIS" o "PRO - X" vs "PRO-X" no consuman el margen.
        edit_distance(
            regexp_replace(nombre_anterior, r'[^A-ZÑ0-9]', ''),
            regexp_replace(nombre,          r'[^A-ZÑ0-9]', '')
        ) as distancia_edicion
    from con_anterior
    where nombre_anterior is not null      -- descarta la primera aparición
      and nombre != nombre_anterior        -- solo cambios de nombre

)

select
    partido_key,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    nombre_anterior,
    nombre as nombre_nuevo,
    distancia_edicion,
    case when distancia_edicion <= 2 then 'ORTOGRAFICO' else 'SUSTANTIVO' end as tipo_cambio,
    case when nombre_propio is distinct from nombre_propio_anterior
         then 'PROPIO' else 'HEREDADO_NACIONAL' end as origen_cambio,
    fecha_snapshot_anterior,
    snapshot_date as fecha_deteccion
from cambios
