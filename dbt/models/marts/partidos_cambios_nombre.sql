{{ config(materialized='table') }}

-- Cambios de nombre por partido: una fila por cada vez que un partido pasa a
-- llamarse distinto. Cada fila se lee: "llevó el nombre X desde A hasta B, y a
-- partir del cierre C pasó a llamarse Y". Registra TODOS los cambios (incluidas
-- idas y vueltas A->B->A: cada tramo de A tiene su propio desde/hasta).
--
-- Fuente: int_partidos (el nombre que ve el tablero, ya normalizado, corregido
-- por seed y con la regla del nombre del nacional aplicada). Los cambios
-- cosméticos del Excel (espacios, tildes, mayúsculas) no aparecen porque
-- staging ya los absorbe.
--
-- Tramos de nombre: meses consecutivos (en las apariciones del partido) con el
-- mismo nombre. Una ausencia del partido NO corta el tramo: si falta algunos
-- cierres y vuelve con el mismo nombre, el nombre no cambió (las ausencias ya
-- quedan registradas en partidos_historia). Fechas como en partidos_historia:
-- intervalo cerrado de cierres realmente observados.
--
-- Clasificación:
--   tipo_cambio:   ORTOGRAFICO si la distancia de edición (sin espacios ni
--                  puntuación) es <= 2 letras; SUSTANTIVO si es mayor.
--   origen_cambio: PROPIO si cambió el nombre propio del partido (stg_partidos);
--                  HEREDADO_NACIONAL si el propio no cambió y el cambio viene de
--                  heredar el nombre del nacional (regla de int_partidos).

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

-- Marca el inicio de un tramo de nombre: primera aparición o nombre distinto
-- al de la aparición anterior del mismo partido.
marcado as (

    select
        *,
        case
            when lag(nombre) over w is null   then 1
            when nombre != lag(nombre) over w then 1
            else 0
        end as es_nuevo_tramo
    from base
    window w as (partition by partido_key order by snapshot_date)

),

-- Suma acumulada de las marcas: id de tramo por partido (gaps and islands).
-- Se toma el nombre propio del primer y del último cierre de cada tramo,
-- para clasificar el origen del cambio en el borde entre tramos.
islas as (

    select
        *,
        sum(es_nuevo_tramo) over (
            partition by partido_key order by snapshot_date
        ) as tramo_id
    from marcado

),

con_bordes as (

    select
        *,
        first_value(nombre_propio) over t as propio_inicio_tramo,
        last_value(nombre_propio)  over t as propio_fin_tramo
    from islas
    window t as (
        partition by partido_key, tramo_id
        order by snapshot_date
        rows between unbounded preceding and unbounded following
    )

),

-- Una fila por tramo de nombre.
tramos as (

    select
        partido_key,
        tramo_id,
        any_value(orden)               as orden,
        any_value(nro_distrito)        as nro_distrito,
        any_value(distrito)            as distrito,
        any_value(nro_partido)         as nro_partido,
        any_value(nombre)              as nombre,
        min(snapshot_date)             as desde,
        max(snapshot_date)             as hasta,
        any_value(propio_inicio_tramo) as propio_inicio_tramo,
        any_value(propio_fin_tramo)    as propio_fin_tramo
    from con_bordes
    group by partido_key, tramo_id

),

-- Cada tramo (salvo el primero) es un cambio respecto del tramo anterior.
con_tramo_anterior as (

    select
        *,
        lag(nombre)           over w as nombre_anterior,
        lag(desde)            over w as nombre_anterior_desde,
        lag(hasta)            over w as nombre_anterior_hasta,
        lag(propio_fin_tramo) over w as propio_fin_tramo_anterior
    from tramos
    window w as (partition by partido_key order by tramo_id)

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
    from con_tramo_anterior
    where nombre_anterior is not null      -- el primer tramo no es un cambio

)

select
    partido_key,
    orden,
    nro_distrito,
    distrito,
    nro_partido,
    nombre_anterior,
    nombre_anterior_desde,
    nombre_anterior_hasta,
    nombre as nombre_nuevo,
    desde  as fecha_cambio_nombre,
    distancia_edicion,
    case when distancia_edicion <= 2 then 'ORTOGRAFICO' else 'SUSTANTIVO' end as tipo_cambio,
    case when propio_inicio_tramo is distinct from propio_fin_tramo_anterior
         then 'PROPIO' else 'HEREDADO_NACIONAL' end as origen_cambio
from cambios
