-- Regla de negocio: un partido de DISTRITO que integra un partido NACIONAL
-- (mismo número) suele llamarse igual que el nacional. Estandarizamos el nombre
-- al del nacional SOLO cuando es una variación de escritura (nombres parecidos).
-- Si el nombre difiere demasiado (misma numeración pero nombre realmente distinto,
-- p.ej. por error o decisión judicial), NO se reemplaza: se marca para revisión.
-- Los nombres ya vienen normalizados desde staging.

with base as (

    select * from {{ ref('stg_partidos') }}

),

-- Nombre oficial de cada nacional, por snapshot y número de partido.
nacionales as (

    select
        snapshot_date,
        nro_partido,
        partido_politico as nombre_nacional
    from base
    where orden = 'NACIONAL'

),

-- Trae el nombre del nacional correspondiente y mide qué tan parecidos son,
-- con distancia de edición (Levenshtein) normalizada por el largo mayor.
comparado as (

    select
        b.*,
        n.nombre_nacional,
        case
            when n.nombre_nacional is not null then
                edit_distance(b.partido_politico, n.nombre_nacional)
                    / greatest(length(b.partido_politico), length(n.nombre_nacional))
        end as dist_norm
    from base b
    left join nacionales n
        on  n.snapshot_date = b.snapshot_date
        and n.nro_partido   = b.nro_partido
        and b.integra_partido_nacional = true

),

final as (

    select
        partido_key,
        orden,
        nro_distrito,
        distrito,
        nro_partido,

        -- Reemplaza por el nombre del nacional solo si son suficientemente parecidos
        -- (variación de escritura). Umbral: distancia normalizada <= 0.40.
        case
            when nombre_nacional is not null and dist_norm <= 0.40
                then nombre_nacional
            else partido_politico
        end as partido_politico,

        -- Bandera: integra un nacional pero el nombre difiere demasiado -> revisar.
        (nombre_nacional is not null and dist_norm > 0.40) as revisar_nombre_nacional,

        -- Nombre del nacional sugerido, solo para los casos a revisar (null si no).
        case
            when nombre_nacional is not null and dist_norm > 0.40
                then nombre_nacional
        end as nombre_nacional_sugerido,

        sigla,
        fecha_reconocimiento,
        integra_partido_nacional,
        snapshot_date

    from comparado

)

select * from final
