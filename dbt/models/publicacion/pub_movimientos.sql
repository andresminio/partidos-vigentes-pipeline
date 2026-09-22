-- Capa de PRESENTACIÓN de los movimientos mensuales para la hoja "Mov mensuales".
-- snapshot_date -> fecha_cierre (dd-mm-aaaa). altas/bajas/neto tal cual (neto es la
-- diferencia altas - bajas). El Apps Script solo vuelca esta vista.

select
    row_number() over (order by snapshot_date) as orden_fila,

    format_date('%d-%m-%Y', snapshot_date) as fecha_cierre,
    anio,
    mes,
    altas,
    bajas,
    neto

from {{ ref('movimientos_mensuales') }}
