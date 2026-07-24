# Pipeline — Registro de Partidos Políticos 

Pipeline mensual que ingesta el listado oficial de partidos políticos vigentes publicado por la Cámara Nacional Electoral (CNE), lo historiza en BigQuery y lo deja listo para consumo analítico en Tableau.

La capa raw preserva los datos tal cual fueron generados por la fuente, incorporando metadatos de trazabilidad. La transformación, limpieza e historización (SCD Tipo 2) se implementan en dbt.

## Decisiones de diseño

- Raw inmutable: se preserva una capa raw sin transformaciones para auditoría
- Separación de responsabilidades: ingestión (Python) vs transformación (dbt)
- SCD Tipo 2: historización completa de cambios en entidades
- Trazabilidad: metadatos por fila para lineage
- Determinismo: snapshot_date derivado del nombre del archivo 
- Idempotencia: prevención de duplicados por diseño a partir de metadatos generados (_source_file)

## Arquitectura
```
Excel mensual
      │
      ▼
Cloud Storage (bucket)
      │
      ▼
Python (ingest) 
- detección de archivos nuevos 
- validación de nombres
- extracción de snapshot_date 
- parsing de Excel 
- enriquecimiento con metadatos 
- carga a BigQuery
      │
      ▼
BigQuery (raw.partidos_snapshot)
- particionada por snapshot_date (MONTH) 
- clusterizada por distrito  
      │
      ▼
dbt  
- staging 
- snapshots (SCD Tipo 2) 
- marts
      │
      ▼
Tableau (BI)
      │
      ▼
Airflow (orquestación mensual)
```

## Stack

- **Ingesta:** Python (pandas, openpyxl)
- **Almacenamiento:** Google Cloud Storage + BigQuery
- **Transformación:** dbt (staging, snapshots SCD2, marts)
- **Orquestación:** Apache Airflow (ejecución mensual)
- **Visualización:** Tableau

## Estructura del repositorio

Los módulos siguen un diseño modular con prefijo numérico según orden de ejecución:

| Módulo | Descripción |
|--------|-----|
| `01_config.py` | Configuración (project_id, bucket, dataset, región, patrón de archivos) |
| `02_storage.py` | Interacción con Cloud Storage (listado y lectura de archivos) |
| `03_parser.py` | Validación, extracción de `snapshot_date`, normalización de columnas, incorporación de metadatos |
| `04_bigquery_loader.py` | Carga a `raw.partidos_snapshot` en BigQuery (schema explícito, partición, clustering) |
| `05_ingest.py` | Orquestador (Punto de entrada) |

## Esquema y metadatos

Esquema 

| Campo | Descripción |
|------|-------------|
| `orden` | tipo de organización partidaria: DISTRITO o NACIONAL. Estable por entidad. Origen del prefijo D o N de la clave en staging. |
| `nro_orden` | código de distrito, sin padding. Para partido NACIONAL es el distrito del juzgado sede. |
| `distrito` | nombre del distrito. |
| `nro_partido` | número del partido en el distrito, sin padding. Los distritales que integran un nacional comparten su número. |
| `nombre` | denominación del partido. Los distritales que integran un nacional comparten su nombre. |
| `sigla` | siglas partidarias. Puede venir vacía o con separadores diferentes entre letras. |
| `fecha_reconocimiento` | Fecha de reconocimiento. Sin parsear. El parseo tolerante a formatos mixtos vive en staging. |
| `integra_on` | indicador binario de si el partido de distrito integra un partido nacional. No identifica a cuál, lo que se deriva del número y nombre del partido. |

Metadatos incorporados

| Campo | Descripción |
|------|-------------|
| `snapshot_date` | Fecha de corte (derivada del nombre del archivo). |
| `_source_file` | Nombre archivo de origen. |
| `_ingested_at` | Timestamp de carga (UTC). |
| `_row_number` | Número de fila dentro del Excel. |

## Idempotencia

El pipeline detecta qué archivos del bucket aún no fueron procesados (comparando contra _source_file en BigQuery), los ingesta en orden cronológico y omite los ya cargados. Ejecutar el pipeline múltiples veces no genera duplicados.


## Fuente

Registro Nacional de Agrupaciones Políticas
Cámara Nacional Electoral (CNE) — Argentina
Publicación mensual en Excel
~700 registros por snapshot

## Autor

Andrés Miño - andresminio@gmail.com