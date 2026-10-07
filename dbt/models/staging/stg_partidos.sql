{{ config(materialized='view') }}

with fuente as (

    select * from {{ source('registro', 'partidos_snapshot') }}

),

-- Tabla oficial de distritos (número -> nombre canónico).
distritos as (

    select nro_distrito, distrito as distrito_oficial
    from {{ ref('distritos') }}

),

normalizado as (

    select
        orden,

        -- La fuente publica el Excel con dos convenciones de encabezado según la
        -- descarga; el parser solo pasa los headers a snake_case, así que el mismo
        -- dato puede caer en columnas distintas. Se toleran ambas con coalesce:
        --   nro distrito: n_orden  | n_distrito
        --   nombre:       nombre   | partido_politico
        --   fecha recon.: fecha_reconocimiento | fecha_de_reconocimiento
        --   integra nac.: integra_on           | integra_un_partido_nacional
        -- (orden, distrito, n_partido, sigla normalizan igual en las dos.)

        -- Códigos como texto padeado: son identificadores, no cantidades.
        -- El cast intermedio a int normaliza "2", "02" y "2.0" antes de padear,
        -- para que la clave sea estable entre archivos aunque Excel tipe distinto.
        lpad(cast(cast(safe_cast(coalesce(n_orden, n_distrito) as numeric) as int64) as string), 2, '0') as nro_distrito,

        -- Nombre de distrito normalizado (mayúsculas, trim, colapsa espacios),
        -- para compararlo limpio contra el seed.
        upper(trim(regexp_replace(distrito, r'\s+', ' '))) as distrito,

        lpad(cast(cast(safe_cast(n_partido as numeric) as int64) as string), 3, '0') as nro_partido,

        -- Nombre tal cual vino en el Excel (sin tocar), para trazabilidad: permite
        -- distinguir lo que trae el raw de lo que modifica el procesamiento.
        coalesce(nombre, partido_politico) as nombre_crudo,

        -- Nombre de partido normalizado igual, más quita de acentos (preserva ñ).
        upper(trim(regexp_replace({{ sin_acentos('coalesce(nombre, partido_politico)') }}, r'\s+', ' '))) as partido_politico,
        sigla,

        -- La fecha llega en tres formatos según el archivo:
        --   - datetime ISO "YYYY-MM-DD 00:00:00" (Excel la trae como fecha real)
        --   - texto "D/M/AAAA" (formato argentino con barras)
        --   - texto "D-M-AAAA" (formato argentino con guiones)
        -- safe_cast solo entiende ISO, por eso el texto daba null. Se prueban los
        -- tres; el ISO va primero para que las fechas con guiones ISO no se
        -- confundan con el formato D-M-AAAA.
        coalesce(
            date(safe_cast(coalesce(fecha_reconocimiento, fecha_de_reconocimiento) as datetime)),
            safe.parse_date('%d/%m/%Y', trim(coalesce(fecha_reconocimiento, fecha_de_reconocimiento))),
            safe.parse_date('%d-%m-%Y', trim(coalesce(fecha_reconocimiento, fecha_de_reconocimiento)))
        ) as fecha_reconocimiento,

        -- 'SI'/'NO' -> booleano.
        (coalesce(integra_on, integra_un_partido_nacional) = 'SI') as integra_partido_nacional,

        -- Fecha de corte del snapshot (ya viene como DATE del raw).
        snapshot_date,

        -- Timestamp de ingesta (cuándo se procesó este cierre). Se arrastra tal cual.
        _ingested_at

    from fuente

),

-- Correcciones puntuales de nro_distrito mal cargado en la fuente (el número
-- no coincide con la identidad del partido). Solo se corrige lo listado en el
-- seed; el resto pasa intacto. Se aplica ANTES de canonizar el distrito y de
-- armar la clave, para que número y nombre queden consistentes y el warning
-- de inconsistencia desaparezca.
correcciones as (

    select snapshot_date, orden, nro_distrito, nro_partido, nro_distrito_correcto
    from {{ ref('correcciones_distrito') }}

),

corregido as (

    select
        n.* except(nro_distrito),
        coalesce(c.nro_distrito_correcto, n.nro_distrito) as nro_distrito
    from normalizado n
    left join correcciones c
        on  n.snapshot_date = c.snapshot_date
        and n.orden         = c.orden
        and n.nro_distrito  = c.nro_distrito
        and n.nro_partido   = c.nro_partido

),

-- Correcciones puntuales de nombre mal cargado (anotación colada en el nombre,
-- o nombre incorrecto del propio nacional). snapshot_date nulo -> aplica a todos
-- los meses de la entidad; con fecha -> solo ese mes. Se aplica antes de la regla
-- de nombre del nacional (int_partidos) para que el nombre corregido propague.
correcciones_nombre as (

    select snapshot_date, orden, nro_distrito, nro_partido, nombre_correcto
    from {{ ref('correcciones_nombre') }}

),

-- Equivalencias de nombre (errores de escritura conocidos, p.ej. "POR-" por
-- "PRO-"): se aplican por nombre en todos los partidos y cierres, después de la
-- limpieza general y antes de las correcciones puntuales del seed anterior.
equivalencias as (

    select nombre_variante, nombre_canonico
    from {{ ref('equivalencias_nombre') }}

),

corregido_nombre as (

    select
        n.* except(partido_politico),
        -- De lo general a lo particular: limpieza de formato (macro limpiar_nombre,
        -- ej. "*VER COLUMNA", espacios alrededor del guion) -> equivalencia por
        -- nombre (seed equivalencias_nombre) -> corrección puntual del partido
        -- (seed correcciones_nombre), que tiene la última palabra.
        coalesce(
            cn.nombre_correcto,
            eq.nombre_canonico,
            {{ limpiar_nombre('n.partido_politico') }}
        ) as partido_politico,
        -- Trazabilidad: qué paso de este bloque modificó el nombre (el más
        -- específico que actuó). Nulo si ninguno lo tocó.
        case
            when cn.nombre_correcto is not null
                 and cn.nombre_correcto != n.partido_politico then 'CORRECCION_PUNTUAL'
            when eq.nombre_canonico is not null then 'EQUIVALENCIA'
            when {{ limpiar_nombre('n.partido_politico') }} != n.partido_politico then 'LIMPIEZA_FORMATO'
        end as motivo_nombre
    from corregido n
    left join equivalencias eq
        on eq.nombre_variante = {{ limpiar_nombre('n.partido_politico') }}
    left join correcciones_nombre cn
        on  n.orden        = cn.orden
        and n.nro_distrito = cn.nro_distrito
        and n.nro_partido  = cn.nro_partido
        and (cn.snapshot_date is null or cn.snapshot_date = n.snapshot_date)

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
    from corregido_nombre n
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

-- Backfill de fecha_reconocimiento cuando falta en un mes puntual. Es un dato
-- INMUTABLE (la fecha de reconocimiento legal no cambia), así que se completa con
-- la ÚLTIMA fecha válida del mismo partido (la no-nula más reciente de su historia):
-- si en algún cierre la corrigieron, se toma esa. Evita perder la fecha porque un
-- mes vino con la celda vacía.
rellenado_fecha as (

    select
        * except(fecha_reconocimiento),
        coalesce(
            fecha_reconocimiento,
            last_value(fecha_reconocimiento ignore nulls) over (
                partition by orden, nro_distrito, nro_partido
                order by snapshot_date
                rows between unbounded preceding and unbounded following
            )
        ) as fecha_reconocimiento
    from rellenado

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
        nombre_crudo,
        motivo_nombre,
        sigla,
        fecha_reconocimiento,
        integra_partido_nacional,
        snapshot_date,
        _ingested_at

    from rellenado_fecha

),

-- Correcciones de nombre decididas en la validación humana de cambios de nombre
-- (decision = ERROR_CARGA en decisiones_cambios_nombre.registro): el nombre del
-- partido se reemplaza por nombre_correcto en los cierres del rango
-- [corregir_desde, corregir_hasta]. Se aplican al final de staging, así tienen la
-- última palabra sobre las demás correcciones. Si dos decisiones se superponen
-- en un mismo cierre, gana la más reciente.
correcciones_decididas as (

    select partido_key, corregir_desde, corregir_hasta, nombre_correcto, decidido_en
    from {{ ref('stg_decisiones_cambios_nombre') }}
    where decision = 'ERROR_CARGA'

),

final as (

    select
        s.* replace (
            coalesce(cd.nombre_correcto, s.partido_politico) as partido_politico,
            -- Trazabilidad final del nombre en staging: la decisión de validación
            -- gana; si no hubo otro motivo pero el nombre difiere del crudo, lo
            -- cambió la normalización (mayúsculas, acentos, espacios).
            case
                when cd.nombre_correcto is not null then 'ERROR_CARGA'
                when s.motivo_nombre is not null then s.motivo_nombre
                when s.nombre_crudo is distinct from s.partido_politico then 'NORMALIZACION'
            end as motivo_nombre
        )
    from staging s
    left join correcciones_decididas cd
        on  cd.partido_key = s.partido_key
        and s.snapshot_date between cd.corregir_desde and cd.corregir_hasta
    qualify row_number() over (
        partition by s.partido_key, s.snapshot_date
        order by cd.decidido_en desc
    ) = 1

)

select * from final
