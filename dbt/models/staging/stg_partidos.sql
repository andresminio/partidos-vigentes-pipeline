{{ config(materialized='view') }}

with fuente as (

    select * from {{ source('cne', 'partidos_snapshot') }}

),

normalizado as (

    select
        orden,

        -- Códigos como texto padeado: son identificadores, no cantidades.
        -- El cast intermedio a int normaliza "2", "02" y "2.0" antes de padear,
        -- para que la clave sea estable entre archivos aunque Excel tipe distinto.
        lpad(cast(cast(safe_cast(n_orden   as numeric) as int64) as string), 2, '0') as nro_distrito,
        distrito,
        lpad(cast(cast(safe_cast(n_partido as numeric) as int64) as string), 3, '0') as nro_partido,

        nombre as partido_politico,
        sigla,

        -- El crudo es un datetime (YYYY-MM-DD 00:00:00); se extrae la fecha.
        date(safe_cast(fecha_reconocimiento as datetime)) as fecha_reconocimiento,

        -- 'SI'/'NO' -> booleano.
        (integra_on = 'SI') as integra_partido_nacional,

        -- Fecha de corte del snapshot (ya viene como DATE del raw).
        snapshot_date

    from fuente

),

staging as (

    select
        -- Clave única de la organización partidaria.
        -- tipo_orden (N/D) + nro_distrito (pad 2) + nro_partido (pad 3), p.ej. D-02-154.
        -- El prefijo es obligatorio: nacional y distrital comparten número en el
        -- distrito sede, y sin prefijo colapsarían en la misma clave.
        concat(
            case orden when 'NACIONAL' then 'N' else 'D' end, '-',
            nro_distrito, '-', nro_partido
        ) as partido_key,

        orden,
        nro_distrito,
        distrito,
        nro_partido,
        partido_politico,
        sigla,
        fecha_reconocimiento,
        integra_partido_nacional,
        snapshot_date

    from normalizado

)

select * from staging
