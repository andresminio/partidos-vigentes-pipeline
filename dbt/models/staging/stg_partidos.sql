{{ config(materialized='view') }}

with fuente as (

    select * from {{ source('cne', 'partidos_snapshot') }}

),

-- Tabla oficial de distritos (número -> nombre canónico).
distritos as (

    select nro_distrito, distrito as distrito_oficial
    from {{ ref('distritos') }}

),

normalizado as (

    select
        orden,

        -- Códigos como texto padeado: son identificadores, no cantidades.
        -- El cast intermedio a int normaliza "2", "02" y "2.0" antes de padear,
        -- para que la clave sea estable entre archivos aunque Excel tipe distinto.
        lpad(cast(cast(safe_cast(n_orden   as numeric) as int64) as string), 2, '0') as nro_distrito,

        -- Nombre de distrito normalizado (mayúsculas, trim, colapsa espacios),
        -- para compararlo limpio contra el seed.
        upper(trim(regexp_replace(distrito, r'\s+', ' '))) as distrito,

        lpad(cast(cast(safe_cast(n_partido as numeric) as int64) as string), 3, '0') as nro_partido,

        -- Nombre de partido normalizado igual.
        upper(trim(regexp_replace(nombre, r'\s+', ' '))) as partido_politico,
        sigla,

        -- El crudo es un datetime (YYYY-MM-DD 00:00:00); se extrae la fecha.
        date(safe_cast(fecha_reconocimiento as datetime)) as fecha_reconocimiento,

        -- 'SI'/'NO' -> booleano.
        (integra_on = 'SI') as integra_partido_nacional,

        -- Fecha de corte del snapshot (ya viene como DATE del raw).
        snapshot_date

    from fuente

),

-- Compara el nombre de distrito que vino contra el oficial del seed.
con_distrito as (

    select
        n.*,
        d.distrito_oficial,
        case when d.distrito_oficial is not null then
            edit_distance(n.distrito, d.distrito_oficial)
                / greatest(length(n.distrito), length(d.distrito_oficial))
        end as dist_distrito
    from normalizado n
    left join distritos d using (nro_distrito)

),

-- Backfill de nro_partido cuando falta en un mes puntual (hueco de carga en el
-- Excel de ese mes). Se completa con el número del MISMO partido (mismo distrito
-- + nombre) tomado del snapshot no-nulo más cercano: primero el mes anterior más
-- reciente y, si no hay, el mes siguiente más próximo. El número es identidad del
-- partido, así que reconstruirlo desde su propia historia es determinístico y no
-- inventa datos. Si un partido cambió de número, toma el vigente en esa época.
rellenado as (

    select
        * except(nro_partido),
        coalesce(
            nro_partido,
            last_value(nro_partido ignore nulls) over (
                partition by nro_distrito, partido_politico
                order by snapshot_date
                rows between unbounded preceding and 1 preceding
            ),
            first_value(nro_partido ignore nulls) over (
                partition by nro_distrito, partido_politico
                order by snapshot_date
                rows between 1 following and unbounded following
            )
        ) as nro_partido
    from con_distrito

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

        -- Estandariza al nombre oficial si es parecido (variación de escritura).
        -- Umbral estricto (0.20) porque los nombres son cortos y algunos se parecen
        -- (SAN JUAN / SAN LUIS). Si es groseramente distinto, deja el original.
        case when distrito_oficial is not null and dist_distrito <= 0.20
             then distrito_oficial
             else distrito
        end as distrito,

        -- Bandera: número y nombre se contradicen (ej. nro 6 con "CAPITAL FEDERAL").
        -- No se pisa; se marca para revisión manual.
        (distrito_oficial is not null and dist_distrito > 0.20) as revisar_distrito,
        case when distrito_oficial is not null and dist_distrito > 0.20
             then distrito_oficial
        end as distrito_oficial_sugerido,

        nro_partido,
        partido_politico,
        sigla,
        fecha_reconocimiento,
        integra_partido_nacional,
        snapshot_date

    from rellenado

)

select * from staging
