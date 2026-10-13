{{ config(materialized='table') }}

-- DETECCIÓN de cambios de nombre (capa intermedia, sin curar). Cada cambio
-- detectado pasa a validación humana (src/validar.py): si se acepta aparece en el
-- mart partidos_cambios_nombre; si es un error de carga, staging reemplaza el
-- nombre por el correcto y el cambio deja de detectarse.
--
-- Una fila por cada vez que un partido pasa a
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
--   origen_cambio: CAMBIO_NACIONAL si el distrito usaba el nombre del nacional que
--                  integra antes y después del cambio (el cambio es el del
--                  nacional; no se valida, sigue su decisión). PROPIO en cualquier
--                  otro caso, incluido empezar o dejar de integrar (se valida).

with nombres_finales as (

    select
        partido_key,
        snapshot_date,
        orden,
        nro_distrito,
        distrito,
        nro_partido,
        partido_politico as nombre,
        usa_nombre_nacional
    from {{ ref('int_partidos') }}

),

base as (

    select * from nombres_finales

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
-- Se toma si el distrito usaba el nombre del nacional en el primer y en el
-- último cierre de cada tramo, para clasificar el origen del cambio en el borde
-- entre tramos.
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
        first_value(usa_nombre_nacional) over t as nacional_inicio_tramo,
        last_value(usa_nombre_nacional)  over t as nacional_fin_tramo
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
        any_value(nacional_inicio_tramo) as nacional_inicio_tramo,
        any_value(nacional_fin_tramo)    as nacional_fin_tramo
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
        lag(nacional_fin_tramo) over w as nacional_fin_tramo_anterior
    from tramos
    window w as (partition by partido_key order by tramo_id)

),

cambios as (

    select *
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
    hasta  as nombre_nuevo_hasta,
    case when nacional_inicio_tramo and nacional_fin_tramo_anterior
         then 'CAMBIO_NACIONAL' else 'PROPIO' end as origen_cambio
from cambios
