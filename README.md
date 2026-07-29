# Pipeline — Registro de Partidos Políticos 

Pipeline mensual que ingesta el listado oficial de partidos políticos vigentes publicado por la Cámara Nacional Electoral (CNE), lo historiza en BigQuery y lo deja listo para consumo analítico en Tableau.

La capa raw preserva los datos tal cual fueron generados por la fuente, incorporando metadatos de trazabilidad. La transformación, limpieza e historización (SCD Tipo 2) se implementan en dbt.

## Decisiones de diseño

- Raw inmutable: se preserva una capa raw sin transformaciones para auditoría
- Separación de responsabilidades: ingestión (Python) vs transformación (dbt)
- SCD Tipo 2: historización completa de cambios en entidades
- Trazabilidad: metadatos por fila para lineage
- Determinismo: snapshot_date derivado del nombre del archivo 
- Idempotencia: prevención de duplicados por diseño, deduplicando por `snapshot_date` (la clave real del snapshot, no el nombre del archivo)
- Nombre estándar: al subir al bucket, cada archivo se renombra a una forma canónica (`partidos_vigentes_DD_MM_YYYY.xlsx`)

## Arquitectura
```
Excel mensual (carpeta local)
      │
      ▼
Python (upload)
- validación de nombres (formato flexible)
- deduplicación por snapshot_date
- subida al bucket con nombre estándar
      │
      ▼
Cloud Storage (bucket)
      │
      ▼
Python (ingest) 
- detección de meses nuevos (por snapshot_date)
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

Nombres descriptivos por responsabilidad. El flujo mensual son dos pasos: `upload.py` (carpeta local → bucket) y luego `ingest.py` (bucket → BigQuery), como en el diagrama de arquitectura de arriba:

| Módulo | Descripción |
|--------|-----|
| `config.py` | Define las constantes de configuración (project_id, bucket, dataset, región, carpeta local, patrón de archivos). |
| `storage.py` | Define funciones para interactuar con Cloud Storage (listar, leer y subir archivos). |
| `parser.py` | Define funciones de validación, extracción de `snapshot_date`, nombre canónico, normalización de columnas e incorporación de metadatos. |
| `bigquery_loader.py` | Define funciones para crear el dataset y cargar a `raw.partidos_snapshot` (schema explícito, partición, clustering), y para consultar los `snapshot_date` ya cargados. |
| `upload.py` | **Punto de entrada 1**: sube los Excel nuevos de la carpeta local al bucket, con nombre estándar y deduplicando por fecha. |
| `ingest.py` | **Punto de entrada 2**: lee los snapshots nuevos del bucket y los carga a `raw.partidos_snapshot`. |

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

El pipeline deduplica por `snapshot_date`, no por nombre de archivo. Detecta qué meses aún no están cargados (comparando contra los `snapshot_date` ya presentes en BigQuery), los ingesta en orden cronológico y omite los ya cargados. La subida al bucket aplica la misma lógica por fecha. Ejecutar el pipeline múltiples veces no genera duplicados, aunque un mismo mes llegue con distinto nombre, capitalización o separador.

## Convención de nombre de archivo

**Archivo de origen (carpeta local).** El nombre determina el `snapshot_date`, así que debe respetar el formato:

```
Partidos [Políticos] Vigentes [al] DD_MM_YYYY.xlsx
```

- **"Políticos" opcional:** valen tanto `Partidos Vigentes ...` como `Partidos Políticos Vigentes ...`.
- **"al" opcional:** la CNE a veces lo omite (`Partidos Políticos Vigentes 30-11-2025.xlsx`).
- **Separador de fecha flexible:** admite guion bajo o guion medio (`31_10_2025` o `31-10-2025`), porque la CNE publica con ambos.
- **Capitalización y acentos libres:** `PARTIDOS VIGENTES AL ...` o `Partidos vigentes al ...` son igualmente válidos.
- Los archivos que no cumplan el formato se ignoran (no se suben al bucket ni se cargan a BigQuery).

**Nombre en el bucket (estándar).** Al subir, cada archivo se renombra a una forma canónica derivada de la fecha, para mantener el bucket consistente:

```
partidos_vigentes_DD_MM_YYYY.xlsx
```


## Fuente

Registro Nacional de Agrupaciones Políticas
Cámara Nacional Electoral (CNE) — Argentina
Publicación mensual en Excel
~700 registros por snapshot

## Autor

Andrés Miño - andresminio@gmail.com