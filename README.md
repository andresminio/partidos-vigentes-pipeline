# Pipeline — Registro de Partidos Políticos

Pipeline mensual que ingesta el listado oficial de partidos políticos vigentes publicado por la Cámara Nacional Electoral (CNE), lo historiza en BigQuery con SCD Tipo 2 y lo deja listo para consumo analítico.

La ingesta (Python) preserva una capa **raw** inmutable con los datos tal cual llegan de la fuente, más metadatos de trazabilidad. La limpieza, las reglas de negocio, la historización y las tablas de consumo se implementan en **dbt** sobre BigQuery. El consumo final se hace desde **Looker Studio** (conexión nativa a BigQuery).

## Decisiones de diseño

- **Raw inmutable:** se preserva una capa raw sin transformaciones para auditoría; toda la lógica vive en dbt.
- **Separación de responsabilidades:** ingesta (Python) vs. transformación (dbt).
- **Idempotencia por `snapshot_date`:** se deduplica por la fecha del snapshot (la clave real), no por el nombre del archivo. Reejecutar el pipeline no genera duplicados.
- **Nombre estándar en el bucket:** al subir, cada archivo se renombra a `partidos_vigentes_DD_MM_YYYY.xlsx`.
- **Clave de negocio determinística:** `tipo_orden (N/D) + nro_distrito (pad 2) + nro_partido (pad 3)`, ej. `D-02-154`. El prefijo N/D es obligatorio porque un nacional y su distrital comparten número en el distrito sede.
- **SCD Tipo 2 por vigencia:** una versión por cada tramo continuo en que un partido estuvo presente; los cortes son por baja/realta, con intervalos cerrados `[valid_from, valid_to]`.
- **Reglas de negocio con guarda:** las correcciones automáticas (nombre del nacional, nombre de distrito) solo se aplican cuando el valor entrante se **parece** al canónico; una discrepancia grosera **no** se pisa, se marca con un test `warn` para revisión manual.
- **Calidad testeada:** tests de dbt sobre unicidad de clave, integridad del SCD2 (sin solapamientos, rango válido, un solo vigente) y guardas de inconsistencia.

## Arquitectura

```
Excel mensual (carpeta local)
      │
      ▼
Python (upload)   -> valida nombre, deduplica por snapshot_date, sube con nombre estándar
      │
      ▼
Cloud Storage (bucket)
      │
      ▼
Python (ingest)   -> detecta meses nuevos, parsea, agrega metadatos, carga
      │
      ▼
BigQuery  raw.partidos_snapshot   (particionada por snapshot_date [MONTH], clusterizada por distrito)
      │
      ▼
dbt
  ├─ source            -> declara raw.partidos_snapshot
  ├─ staging           -> tipado, clave, normalización de nombres, distrito canónico (seed)
  ├─ intermediate      -> nombre del nacional para los distritales que lo integran
  ├─ SCD2 (historia)   -> historización por vigencia (valid_from / valid_to / is_current)
  └─ marts             -> partidos_snapshots (detalle), partidos_vigentes, movimientos_mensuales, resumen_mensual_partidos
      │
      ▼
Looker Studio (BI, conexión nativa a BigQuery)
      │
      ▼
Airflow (orquestación mensual)   [pendiente]
```

## Stack

- **Ingesta:** Python (pandas, openpyxl, google-cloud-storage, google-cloud-bigquery)
- **Almacenamiento:** Google Cloud Storage + BigQuery
- **Transformación:** dbt (dbt-bigquery) — staging, intermediate, SCD2, marts, seeds y tests
- **Visualización:** Looker Studio (conexión nativa a BigQuery)
- **Orquestación:** Apache Airflow (ejecución mensual) — pendiente
- **Autenticación local:** Application Default Credentials (ADC), sin claves de service account

## Estructura del repositorio

Dos mitades: `src/` (ingesta en Python) y `dbt/` (transformación).

### Ingesta — `src/`

El flujo mensual son dos pasos: `upload.py` (carpeta local → bucket) y luego `ingest.py` (bucket → BigQuery).

| Módulo | Descripción |
|--------|-----|
| `config.py` | Constantes de configuración (project_id, bucket, dataset, región, carpeta local, patrón de archivos). |
| `storage.py` | Interacción con Cloud Storage (listar, leer y subir archivos). |
| `parser.py` | Validación de nombre, extracción de `snapshot_date`, nombre canónico, normalización de columnas e incorporación de metadatos. |
| `bigquery_loader.py` | Creación del dataset, carga a `raw.partidos_snapshot` (schema explícito, partición, clustering) y consulta de los `snapshot_date` ya cargados. |
| `upload.py` | **Punto de entrada 1:** sube los Excel nuevos al bucket, con nombre estándar y deduplicando por fecha. |
| `ingest.py` | **Punto de entrada 2:** lee los snapshots nuevos del bucket y los carga a `raw.partidos_snapshot`. |

### Transformación — `dbt/`

| Recurso | Capa | Descripción |
|---------|------|-----|
| `stg_partidos` | staging | Tipa los datos crudos, construye `partido_key`, normaliza nombres (mayúsculas, trim, colapsa espacios) y estandariza el nombre de distrito desde el número contra el seed. |
| `int_partidos` | intermediate | Reemplaza el nombre de los partidos de distrito que integran un nacional por el nombre del nacional (solo si son parecidos; con guarda de similitud). |
| `partidos_historia` | SCD2 | Historización por vigencia: una fila por tramo continuo, con `valid_from`, `valid_to`, `is_current`. |
| `partidos_vigentes` | marts | Foto actual del Registro (`is_current`). |
| `movimientos_mensuales` | marts | Altas y bajas por mes (más `neto`). |
| `partidos_snapshots` | marts | Detalle por partido y mes (todos los snapshots); backbone del tablero, con `is_current` y coordenadas por distrito. |
| `resumen_mensual_partidos` | marts | Cantidad de partidos por tipo de orden y mes. |
| `distritos` | seed | Tabla oficial de los 24 distritos electorales: número → nombre canónico y coordenadas (centro de provincia). |

## Esquema y metadatos (raw)

Columnas de datos de la fuente (se cargan como STRING; el tipado vive en staging):

| Campo (raw) | Descripción |
|------|-------------|
| `orden` | Tipo de organización: DISTRITO o NACIONAL. Estable por entidad; origen del prefijo N/D de la clave. |
| `n_orden` | Código de distrito. Para un NACIONAL, el distrito del juzgado sede. En staging pasa a `nro_distrito` (padeado a 2). |
| `distrito` | Nombre del distrito. En staging se estandariza desde el número contra el seed. |
| `n_partido` | Número del partido en el distrito. Los distritales que integran un nacional comparten su número. En staging pasa a `nro_partido` (padeado a 3). |
| `nombre` | Denominación del partido. En staging pasa a `partido_politico` (normalizado; los distritales que integran un nacional toman el nombre del nacional). |
| `sigla` | Siglas partidarias. Puede venir vacía. |
| `fecha_reconocimiento` | Fecha de reconocimiento legal. En staging se parsea a DATE. |
| `integra_on` | SI/NO: si el partido de distrito integra un partido nacional. En staging pasa a `integra_partido_nacional` (booleano). |

> Algunos meses traen columnas extra (ej. `EXPEDIENTE`). La tabla raw las absorbe (`ALLOW_FIELD_ADDITION`) y staging las ignora (selecciona solo las columnas conocidas).

Metadatos incorporados por la ingesta:

| Campo | Descripción |
|------|-------------|
| `snapshot_date` | Fecha de corte, derivada del nombre del archivo (clave de partición). |
| `_source_file` | Nombre del archivo de origen. |
| `_ingested_at` | Timestamp de carga (UTC). |
| `_row_number` | Número de fila dentro del Excel. |

## Calidad de datos y guardas

- **Tests de clave y catálogo (staging):** `partido_key + snapshot_date` único, `partido_key` / `nro_distrito` / `nro_partido` no nulos, `orden` ∈ {DISTRITO, NACIONAL}.
- **Integridad del SCD2 (`partidos_historia`):** grano único (`partido_key + valid_from`), rango válido (`valid_from <= valid_to`), sin solapamientos de vigencia por partido, un solo `is_current` por partido.
- **Guarda de nombre de nacional (`warn`):** marca los distritales cuyo nombre difiere demasiado del nacional del mismo número (no se corrige solo, se revisa).
- **Guarda de distrito (`warn`):** marca contradicciones número↔nombre de distrito (ej. `nro 6` con "CAPITAL FEDERAL" cuando el 6 es CHACO). Umbral estricto porque los nombres son cortos.

## Idempotencia

El pipeline deduplica por `snapshot_date`, no por nombre de archivo. Detecta qué meses aún no están cargados (comparando contra los `snapshot_date` ya presentes en BigQuery), los ingesta en orden cronológico y omite los ya cargados. La subida al bucket aplica la misma lógica por fecha. Ejecutar el pipeline múltiples veces no genera duplicados, aunque un mismo mes llegue con distinto nombre, capitalización o separador.

## Convención de nombre de archivo

**Archivo de origen (carpeta local).** El nombre determina el `snapshot_date`, así que debe respetar el formato:

```
Partidos [Políticos] Vigentes [al] DD_MM_YYYY.xlsx
```

- **"Políticos" opcional:** valen `Partidos Vigentes ...` y `Partidos Políticos Vigentes ...`.
- **"al" opcional:** la CNE a veces lo omite (`Partidos Políticos Vigentes 30-11-2025.xlsx`).
- **Separador de fecha flexible:** guion bajo o guion medio (`31_10_2025` o `31-10-2025`).
- **Capitalización y acentos libres.**
- Los archivos que no cumplan el formato se ignoran (no se suben ni se cargan).

**Nombre en el bucket (estándar).** Al subir, cada archivo se renombra a una forma canónica derivada de la fecha:

```
partidos_vigentes_DD_MM_YYYY.xlsx
```

## Cómo correr el pipeline

```bash
# 1) Ingesta (con el venv activo, desde src/)
python upload.py     # carpeta local -> bucket (solo meses nuevos)
python ingest.py     # bucket -> BigQuery raw (solo meses nuevos)

# 2) Transformación y tests (desde dbt/)
dbt build            # carga seeds, construye modelos y corre todos los tests

# 3) Documentación (opcional)
dbt docs generate && dbt docs serve
```

> **Correcciones:** para reprocesar un mes ya cargado (dato corregido), primero se borra su blob del bucket y su partición en BigQuery, y recién ahí se vuelve a correr `upload` / `ingest`. El pipeline solo agrega meses nuevos; no pisa los existentes.

## Fuente

Registro Nacional de Agrupaciones Políticas
Cámara Nacional Electoral (CNE) — Argentina
Publicación mensual en Excel
~750 registros por snapshot

## Autor

Andrés Miño — andresminio@gmail.com
