{{ config(materialized='view') }}

-- Decisión VIGENTE de la validación humana por cada cambio de nombre revisado.
-- La fuente es de solo inserción: si un cambio se decidió más de una vez,
-- prevalece la decisión más reciente.

select
    partido_key,
    fecha_cambio_nombre,
    nombre_anterior,
    nombre_nuevo,
    decision,
    fundamento,
    nombre_correcto,
    corregir_desde,
    corregir_hasta,
    decidido_por,
    decidido_en
from {{ source('decisiones_cambios_nombre', 'registro') }}
qualify row_number() over (
    partition by partido_key, fecha_cambio_nombre, nombre_anterior, nombre_nuevo
    order by decidido_en desc
) = 1
