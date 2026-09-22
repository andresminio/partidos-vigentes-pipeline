-- Capa de PRESENTACIÓN del resumen mensual para la hoja "Resumen" del Sheet.
-- snapshot_date -> fecha_cierre (dd-mm-aaaa). El resto tal cual. El Apps Script
-- solo vuelca esta vista; el formato vive acá, no en el script.

select
    row_number() over (order by snapshot_date) as orden_fila,

    format_date('%d-%m-%Y', snapshot_date) as fecha_cierre,
    anio,
    mes,
    nacionales,
    distritales,
    total

from {{ ref('resumen_mensual_partidos') }}
