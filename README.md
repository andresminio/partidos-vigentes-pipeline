# Pipeline — Registro de Partidos Políticos (CNE → GCP)

Pipeline mensual que ingesta el listado de partidos políticos vigentes publicado por
la Cámara Nacional Electoral (CNE), lo historiza en BigQuery y lo deja listo para
consumo en Tableau. La capa cruda (`raw`) guarda el Excel **tal cual llega**, con
metadatos de trazabilidad; toda la limpieza y el histórico (SCD tipo 2) viven en dbt.

## Arquitectura

```
Excel mensual
      │
      ▼
Cloud Storage (bucket)
      │
      ▼
Python (este repo)
  - detecta archivos nuevos
  - valida nombre
  - extrae snapshot_date
  - lee Excel
  - agrega metadatos
  - carga a BigQuery
      │
      ▼
BigQuery (raw.partidos_snapshot)   ← particionada por mes, clustered por distrito
      │
      ▼
dbt  (staging + snapshots SCD2)
      │
      ▼
marts
      │
      ▼
Tableau
      │
   (Airflow ejecuta el script cada fin de mes)
```

## Stack

- **Ingesta:** Python 3.11+ (pandas, openpyxl)
- **Almacenamiento:** Google Cloud Storage + BigQuery
- **Transformación:** dbt (staging, snapshots SCD2, marts)
- **Orquestación:** Airflow (mensual)
- **BI:** Tableau

## Estructura

Los módulos llevan prefijo numérico según el orden de ejecución:

| Módulo | Rol |
|--------|-----|
| `01_config.py` | IDs de proyecto/bucket/dataset, región y patrón de nombre de archivo |
| `02_storage.py` | Lista y lee los Excel desde Cloud Storage |
| `03_parser.py` | Valida el nombre, extrae `snapshot_date`, normaliza columnas, agrega metadatos |
| `04_bigquery_loader.py` | Carga a `raw.partidos_snapshot` (schema explícito, partición, clustering) |
| `05_ingest.py` | Orquestador: detecta nuevos, ordena por fecha y carga. **Punto de entrada.** |

> Nota: como los nombres empiezan con dígito, los imports internos usan
> `importlib.import_module(...)` en lugar de `from ... import ...`.

## Metadatos agregados a cada fila

- `snapshot_date` — fecha de corte (derivada del nombre del archivo)
- `_source_file` — archivo de origen
- `_ingested_at` — timestamp de carga (UTC)
- `_row_number` — número de fila dentro del Excel

## Cómo correr

```bash
pip install -r requirements.txt

# Autenticación con GCP (una vez)
gcloud auth application-default login

# Ejecutar la ingesta
python 05_ingest.py
```

El script detecta qué archivos del bucket todavía no fueron cargados (mirando
`_source_file` en BigQuery), los procesa en orden cronológico y saltea los ya
cargados. Es idempotente: correrlo dos veces no duplica datos.

## Fuente

Registro Nacional de Agrupaciones Políticas — Cámara Nacional Electoral (CNE).
Datos públicos. ~700 partidos vigentes por corte mensual.
