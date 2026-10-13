# Pipeline — Registro de Partidos Políticos

Pipeline mensual que ingesta el listado oficial de partidos políticos vigentes, lo historiza en BigQuery con SCD Tipo 2 y lo deja listo para consumo analítico.

La ingesta (Python) preserva una capa **raw** inmutable con los datos tal cual llegan de la fuente, más metadatos de trazabilidad. La limpieza, las reglas de negocio, la historización y las tablas de consumo se implementan en **dbt** sobre BigQuery. El consumo se hace desde **Looker Studio** (conexión nativa a BigQuery) y desde **Google Sheets**, alimentado por una capa de **presentación** (`publicacion`) que un Apps Script vuelca tal cual (todo el formato vive en dbt, no en el script).

## Decisiones de diseño

- **Raw inmutable:** se preserva una capa raw sin transformaciones para auditoría; toda la lógica vive en dbt.
- **Separación de responsabilidades:** ingesta (Python) vs. transformación (dbt).
- **Idempotencia por `snapshot_date`:** se deduplica por la fecha del snapshot (la clave real), no por el nombre del archivo. Reejecutar el pipeline no genera duplicados.
- **Nombre estándar en el bucket:** al subir, cada archivo se renombra a `partidos_vigentes_DD_MM_YYYY.xlsx`.
- **Clave de negocio determinística:** `tipo_orden (N/D) + nro_distrito (pad 2) + nro_partido (pad 3)`, ej. `D-02-154`. El prefijo N/D es obligatorio porque un nacional y su distrital comparten número en el distrito sede.
- **SCD Tipo 2 por vigencia:** una versión por cada tramo continuo en que un partido estuvo presente; los cortes son por baja/realta, con intervalos cerrados `[valid_from, valid_to]`.
- **Reglas de negocio con guarda:** las correcciones automáticas (nombre del nacional, nombre de distrito) solo se aplican cuando el valor entrante se **parece** al canónico; una discrepancia grosera **no** se pisa, se marca con un test `warn` para revisión manual.
- **Backfill de `nro_partido`:** cuando un mes puntual trae el número de partido vacío, se completa determinísticamente con el número del **mismo partido** (distrito + nombre) tomado del snapshot no-nulo más cercano en el tiempo. El número es identidad del partido, así que se reconstruye desde su propia historia sin inventar datos.
- **Correcciones de distrito versionadas (seed):** los errores de carga de la fuente en `nro_distrito` (el número no coincide con la identidad del partido) se corrigen mediante el seed `correcciones_distrito`, no editando el raw. Cada corrección es una fila explícita (snapshot + orden + distrito + partido → distrito correcto), **auditable en git** y aplicada en staging antes de armar la clave. Solo se corrige lo listado; el resto pasa intacto.
- **Limpieza de nombres en cascada, de lo general a lo particular:** (1) normalización (mayúsculas, sin acentos preservando la ñ, espacios colapsados); (2) macro `limpiar_nombre`, reglas de formato globales (quita anotaciones `*VER ...` y `ESPERAR ...`, comillas dobles, espacios alrededor del guion y del lado de adentro de los paréntesis); (3) seed `equivalencias_nombre`, errores de escritura y notas libres conocidas que se corrigen **por nombre en todos los partidos y cierres**; (4) decisiones de la validación humana (`ERROR_CARGA`), solo para un partido y un rango de fechas. Cada paso le gana al anterior.
- **Validación humana de cambios de nombre (human in the loop):** el pipeline detecta los cambios de nombre, pero una persona decide si son reales (`ACEPTADO`) o errores de carga (`ERROR_CARGA` + nombre correcto). Las decisiones son **datos, no código**: viven en BigQuery (`decisiones_cambios_nombre.registro`), centralizadas para todos los que corren el pipeline, en una tabla de **solo inserción** (nunca se edita ni se borra; prevalece la decisión más reciente) con autor y fecha automáticos. Los distritales que heredan el nombre de su nacional heredan también su decisión.
- **Trazabilidad raw vs. procesamiento:** staging conserva el nombre crudo y registra qué paso lo modificó (`motivo_nombre`). La auditoría (`auditoria_cambios_nombre`) muestra **todos** los cambios, por cualquier motivo, separando lo que trajo el Excel de lo que hizo el procesamiento; la tabla oficial (`partidos_cambios_nombre`) muestra solo los homologados.
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
  ├─ staging           -> tipado, clave, limpieza y correcciones de nombre, distrito canónico, trazabilidad
  ├─ intermediate      -> nombre del nacional para los distritales que lo integran; detección de cambios de nombre
  ├─ SCD2 (historia)   -> historización por vigencia (valid_from / valid_to / is_current)
  ├─ marts             -> partidos_snapshots (detalle), partidos_vigentes, movimientos_mensuales, resumen_mensual_partidos,
  │                       partidos_cambios_nombre (homologados), auditoria_cambios_nombre (todos los cambios)
  └─ publicacion       -> vistas de presentación (pub_historizacion, pub_resumen, pub_vigentes, pub_cambios_nombre)
      ▲
      │  decisiones (source)
BigQuery  decisiones_cambios_nombre.registro  <- Python (validar.py): validación humana por consola o Excel
      │
      ├─────────►  Looker Studio (BI, conexión nativa a BigQuery)
      │
      └─────────►  Google Sheets (Apps Script vuelca las vistas pub_*; refresh disparado por el pipeline)
      │
      ▼
Airflow (orquestación mensual)
```

## Stack

- **Ingesta:** Python (pandas, openpyxl, google-cloud-storage, google-cloud-bigquery)
- **Almacenamiento:** Google Cloud Storage + BigQuery
- **Transformación:** dbt (dbt-bigquery) — staging, intermediate, SCD2, marts, seeds y tests
- **Visualización:** Looker Studio (conexión nativa a BigQuery)
- **Publicación:** Google Sheets, alimentado por las vistas `publicacion` vía Apps Script (refresh disparado por el pipeline)
- **Orquestación:** Apache Airflow (ejecución mensual)
- **Autenticación local:** Application Default Credentials (ADC), sin claves de service account

## Tablero

Consumo en Looker Studio: https://datastudio.google.com/reporting/b4efb9aa-1c41-40e6-9f9d-59306971d4c3

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
| `refresh_sheet.py` | Dispara el refresh de las hojas de Google Sheets (llama a cada web app de Apps Script con el token). Las URLs y el token viven en `refresh_config.py`, que **no se commitea**. |
| `reprocesar.py` | Borra un cierre ya cargado (blob del bucket + filas de raw) para recargarlo corregido. Pide confirmación. |
| `validar.py` | Validación humana de cambios de nombre. Consola de a un cambio (casos nuevos), `--exportar` a Excel con todos los pendientes y `--importar` para la carga masiva. Inserta las decisiones en `decisiones_cambios_nombre.registro`. |

### Transformación — `dbt/`

| Recurso | Capa | Descripción |
|---------|------|-----|
| `stg_partidos` | staging | Tipa los datos crudos, aplica las correcciones de distrito, rellena `nro_partido` faltante desde la historia del partido, construye `partido_key` y estandariza el nombre de distrito. Aplica la cascada de limpieza de nombres (normalización → `limpiar_nombre` → `equivalencias_nombre` → decisiones `ERROR_CARGA`) y conserva `nombre_crudo` y `motivo_nombre` para trazabilidad. |
| `stg_decisiones_cambios_nombre` | staging | Decisión vigente (la más reciente) por cada cambio de nombre revisado, desde la fuente `decisiones_cambios_nombre.registro`. |
| `int_partidos` | intermediate | Reemplaza el nombre de los partidos de distrito que integran un nacional por el nombre del nacional (solo si son parecidos; con guarda de similitud). Marca esos casos como `HEREDADO_NACIONAL`. |
| `int_cambios_nombre` | intermediate | Detección de cambios de nombre, sin curar: una fila por cada vez que un partido pasa a llamarse distinto, con el tramo del nombre anterior (desde/hasta), la fecha del cambio y `origen_cambio` (PROPIO o HEREDADO_NACIONAL). |
| `partidos_historia` | SCD2 | Historización por vigencia: una fila por tramo continuo, con `valid_from`, `valid_to`, `is_current`. |
| `partidos_vigentes` | marts | Foto actual del Registro (`is_current`). |
| `movimientos_mensuales` | marts | Altas y bajas por mes (más `neto`). |
| `partidos_snapshots` | marts | Detalle por partido y mes (todos los snapshots); backbone del tablero, con `is_current` y coordenadas por distrito. |
| `resumen_mensual_partidos` | marts | Cantidad de partidos por tipo de orden y mes. |
| `partidos_cambios_nombre` | marts | Cambios de nombre **homologados**: los aceptados en la validación humana, más los heredados de un nacional aceptado. Tabla oficial. |
| `auditoria_cambios_nombre` | marts | **Todos** los cambios de nombre, por partido y cierre (sobre cada cierre, no sobre el SCD2): `nombre_crudo`, `nombre_final` y `motivo`. |
| `distritos` | seed | Tabla oficial de los 24 distritos electorales: número → nombre canónico y coordenadas (centro de provincia). |
| `correcciones_distrito` | seed | Correcciones puntuales de `nro_distrito` mal cargado en la fuente. Una fila por corrección (snapshot + orden + distrito + partido → distrito correcto); auditable en git y aplicada en staging. |
| `equivalencias_nombre` | seed | Errores de escritura conocidos (`nombre_variante → nombre_canonico`), aplicados por nombre en todos los partidos y cierres. La variante se escribe ya limpia (sin acentos, sin `*VER`, sin espacios alrededor del guion). |
| `limpiar_nombre` | macro | Reglas de formato globales sobre el nombre: quita `*VER ...` y `ESPERAR ...`, comillas dobles, espacios alrededor del guion y dentro de los paréntesis. Para sumar una regla se agrega un `regexp_replace`. |
| `pub_historizacion` | publicacion | Presentación de la historización para Google Sheets: nombres finales, SI/NO, fechas dd-mm-aaaa, "cierre actual" en la vigencia abierta y orden de filas. |
| `pub_resumen` | publicacion | Presentación del resumen mensual para Google Sheets (`snapshot_date` como `fecha_cierre`). |
| `pub_vigentes` | publicacion | Presentación de la foto actual (partidos vigentes) para Google Sheets, con fechas dd-mm-aaaa y nombres coherentes con la historización. |
| `pub_cambios_nombre` | publicacion | Presentación de los cambios de nombre homologados para la hoja de cambios de nombre (primera hoja del archivo), con decisión, fecha y fundamento. |

## Esquema y metadatos (raw)

Columnas de datos de la fuente (se cargan como STRING; el tipado vive en staging):

| Campo (raw) | Descripción |
|------|-------------|
| `orden` | Tipo de organización: DISTRITO o NACIONAL. Estable por entidad; origen del prefijo N/D de la clave. |
| `n_orden` | Código de distrito. Para un NACIONAL, el distrito del juzgado sede. En staging pasa a `nro_distrito` (padeado a 2). |
| `distrito` | Nombre del distrito. En staging se estandariza desde el número contra el seed. |
| `n_partido` | Número del partido en el distrito. Los distritales que integran un nacional comparten su número. En staging pasa a `nro_partido` (padeado a 3). |
| `nombre` | Denominación del partido. En staging pasa a `partido_politico` (normalizado y limpio; ver la cascada de limpieza) y se conserva tal cual en `nombre_crudo`. Los distritales que integran un nacional toman el nombre del nacional. |
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
- **Cambios de nombre:** grano único y nombres distintos en la detección y en la tabla homologada; `warn_cambios_nombre_pendientes` lista en cada cierre los cambios sin decisión; `assert_homologacion_huerfana` (`warn`) avisa si un ACEPTADO ya no coincide con ningún cambio detectado; `warn_correccion_no_aplicada` avisa si un ERROR_CARGA sigue apareciendo; la auditoría tiene grano único y valores válidos de `motivo`.

## Idempotencia

El pipeline deduplica por `snapshot_date`, no por nombre de archivo. Detecta qué meses aún no están cargados (comparando contra los `snapshot_date` ya presentes en BigQuery), los ingesta en orden cronológico y omite los ya cargados. La subida al bucket aplica la misma lógica por fecha. Ejecutar el pipeline múltiples veces no genera duplicados, aunque un mismo mes llegue con distinto nombre, capitalización o separador.

**Actualización dentro del mes (reemplazo).** Si llega una versión nueva de un mes ya cargado (ej. `... 31_08_2026 (2).xlsx` o `...-copia.xlsx`), el pipeline la **reemplaza** automáticamente, sin reprocesamiento manual:

- `upload.py` agrupa los archivos locales por `snapshot_date` y sube el de **modificación más reciente** (mtime) al nombre canónico (un blob por fecha). Solo re-sube si el **contenido cambió** (compara `md5`), así no dispara reprocesos al pedo.
- `ingest.py` compara el `updated` del blob contra el `_ingested_at` cargado: si el blob es **más nuevo**, borra las filas de ese mes y recarga la versión nueva; si no, saltea.
- La columna `Actualizado` (ver marts) refleja el `_ingested_at`, así que queda registrado **cuándo** se procesó cada cierre y sus reemplazos.

## Convención de nombre de archivo

**Archivo de origen (carpeta local).** El nombre determina el `snapshot_date`, así que debe respetar el formato:

```
Partidos [Políticos] Vigentes [al] DD_MM_YYYY.xlsx
```

- **"Políticos" opcional:** valen `Partidos Vigentes ...` y `Partidos Políticos Vigentes ...`.
- **"al" opcional:** la fuente a veces lo omite (`Partidos Políticos Vigentes 30-11-2025.xlsx`).
- **Separador de fecha flexible:** guion bajo o guion medio (`31_10_2025` o `31-10-2025`).
- **Capitalización y acentos libres.**
- Los archivos que no cumplan el formato se ignoran (no se suben ni se cargan).

**Nombre en el bucket (estándar).** Al subir, cada archivo se renombra a una forma canónica derivada de la fecha:

```
partidos_vigentes_DD_MM_YYYY.xlsx
```

## Flujo de cambios de nombre

Cada partido se identifica por su `partido_key` (ej. `D-05-218`), pero su **nombre** puede variar entre cierres: algunas variaciones son cambios reales y otras son ruido de carga del Excel (anotaciones, tildes, espacios, errores de tipeo). El flujo separa una cosa de la otra: limpia de forma automática lo que es ruido conocido, detecta lo que queda, una persona decide si es real, y solo lo homologado se publica.

### Recorrido

```
Excel del cierre
   │
   ▼
raw.partidos_snapshot ............ nombre tal cual vino (no se toca)
   │
   ▼
stg_partidos ..................... LIMPIEZA AUTOMÁTICA, de lo general a lo particular
   │   1. normalización (mayúsculas, sin acentos, espacios)        -> todos
   │   2. macro limpiar_nombre (*VER, ESPERAR, comillas, guiones,  -> todos
   │      paréntesis)
   │   3. seed equivalencias_nombre (errores de escritura conocidos) -> todos los que tengan ese nombre
   │   4. decisiones ERROR_CARGA de la validación humana            -> un partido y un rango de fechas
   │   + guarda nombre_crudo y motivo_nombre (qué paso lo cambió)
   ▼
int_partidos ..................... HERENCIA: el distrito que integra un nacional toma su nombre
   │
   ▼
int_cambios_nombre ............... DETECCIÓN: un registro cada vez que un partido pasa a
   │                               llamarse distinto (sin curar)
   ▼
validar.py  ───────────────────►  decisiones_cambios_nombre.registro (BigQuery)
   │  una persona decide:          ACEPTADO  -> pasa a la tabla oficial
   │                               ERROR_CARGA + nombre correcto -> vuelve a staging (paso 4)
   ▼                               y el falso cambio desaparece
partidos_cambios_nombre .......... TABLA OFICIAL: solo los homologados (+ heredados del nacional)
   │
   ▼
pub_cambios_nombre ............... presentación (fechas dd-mm-aaaa, orden)
   │
   ▼
Google Sheet de cambios de nombre  (primera hoja, la vuelca el Apps Script)

En paralelo: auditoria_cambios_nombre -> TODOS los cambios, crudo vs. final, y el motivo
```

### Qué hace cada pieza

| pieza | tipo | qué hace |
|---|---|---|
| `stg_partidos` | modelo dbt (staging) | Aplica la limpieza en cascada y conserva el nombre crudo y el motivo de cada modificación. |
| `limpiar_nombre` | macro dbt | Reglas de formato globales. Para una regla nueva se agrega un `regexp_replace`. |
| `equivalencias_nombre` | seed (git) | `nombre_variante → nombre_canonico`. La variante se escribe ya limpia. Los nombres con coma van entre comillas (sintaxis CSV). |
| `int_partidos` | modelo dbt (intermediate) | Herencia del nombre del nacional; la marca como `HEREDADO_NACIONAL`. |
| `int_cambios_nombre` | modelo dbt (intermediate) | Detecta los cambios: tramo del nombre anterior (desde/hasta), fecha del cambio y `origen_cambio` (PROPIO / HEREDADO_NACIONAL). |
| `validar.py` | script Python (`src/`) | Validación humana: consola, exportación a Excel e importación masiva. Escribe en BigQuery. |
| `decisiones_cambios_nombre.registro` | tabla BigQuery | Decisiones centralizadas (sirven para cualquiera que corra el pipeline). Solo inserción: nunca se edita ni se borra; prevalece la más reciente. Autor y fecha automáticos. |
| `stg_decisiones_cambios_nombre` | modelo dbt (staging) | Decisión vigente por cambio. |
| `partidos_cambios_nombre` | modelo dbt (mart) | Tabla oficial: aceptados + heredados de un nacional aceptado. |
| `pub_cambios_nombre` | vista dbt (publicación) | Formato para la hoja. |
| `auditoria_cambios_nombre` | modelo dbt (mart) | Una fila por partido y cierre en que algo cambió: key, orden, distrito, cierre, `nombre_crudo`, `nombre_final` y `motivo` (`LIMPIEZA_FORMATO`, `NORMALIZACION`, `EQUIVALENCIA`, `HEREDADO_NACIONAL`, `CAMBIO_ACEPTADO`, `ERROR_RECHAZADO` o `PENDIENTE`). Ordenada por key y cierre. |

### Dónde se ve cada cosa

| quiero ver… | dónde |
|---|---|
| Cuántos cambios faltan validar | warning `warn_cambios_nombre_pendientes` al final del `dbt build` / `run_cierre.ps1` |
| Los pendientes para decidir | `python validar.py` (consola) o el Excel de `python validar.py --exportar` en `revision/` |
| Todos los cambios detectados, sin curar | BigQuery: `dbt_dev.int_cambios_nombre` |
| Los cambios homologados (oficial) | Google Sheet de cambios de nombre, o BigQuery: `dbt_dev.partidos_cambios_nombre` / `dbt_dev.pub_cambios_nombre` |
| Las decisiones tomadas (quién, cuándo, por qué) | BigQuery: `decisiones_cambios_nombre.registro` |
| Todo lo que cambió y qué lo resolvió (raw vs. procesamiento) | BigQuery: `dbt_dev.auditoria_cambios_nombre` |
| El nombre final de cada partido en cada cierre | Google Sheet de Historización / vigentes, o BigQuery: `dbt_dev.int_partidos` |

> La hoja de Google es una **copia** de la vista al momento del último refresh. Si se decide algo y no se refresca, la hoja queda desactualizada.

### Ciclo de cada cierre

1. `run_cierre.ps1` corre upload → ingest → `dbt build` → refresh de las hojas. El cierre queda completo.
2. Si hay cambios pendientes, pregunta **"Validar ahora? (s/n)"** (60 s; sin respuesta = no).
   - **s:** abre la consola de `validar.py`; al salir corre `dbt build` y el refresh otra vez.
   - **n:** los cambios quedan pendientes y se avisan en el próximo build.
3. Para validar después, desde `src/`: `python validar.py`, luego `dbt build` (en `dbt/`) y `python refresh_sheet.py`.

Para revisiones grandes (por ejemplo, el histórico): `python validar.py --exportar`, completar el Excel (`decision`, `nombre_correcto` si es error, `fundamento` opcional), `python validar.py --importar ARCHIVO`, y `dbt build`.

### Decisiones

**Heredados:** los distritos que integran un nacional **nunca se validan**: siguen al nacional. Si se acepta el cambio del nacional, sus distritos entran a la tabla oficial; si se marca `ERROR_CARGA`, el nombre del nacional se corrige y los distritos lo heredan corregido. Por eso no aparecen en `validar.py` ni en el warning de pendientes.

| decisión | qué hace |
|---|---|
| `ACEPTADO` | El cambio es real: aparece en la tabla oficial y en la hoja. Si es de un nacional, sus distritos que lo heredan quedan aceptados solos. |
| `ERROR_CARGA` | Se pide el nombre correcto, que reemplaza **a los dos nombres** (anterior y nuevo) de ese partido en todo el rango de la fila. El falso cambio deja de detectarse. Para conservar el nombre viejo, se escribe el nombre viejo. |

### Qué herramienta usar para cada error de nombre

| tipo de error | dónde se corrige | alcance |
|---|---|---|
| Formato o anotación que se repite (`*VER`, `ESPERAR`, comillas, espacios) | macro `limpiar_nombre` | todos los partidos y cierres |
| Error de escritura o nota libre conocida de un nombre | seed `equivalencias_nombre` | todos los partidos con ese nombre, todos los cierres (también los futuros) |
| Cambio de nombre detectado que no es real | `validar.py` → `ERROR_CARGA` | un partido y un rango de fechas |

Regla práctica: si el error es **masivo** o se va a repetir en los próximos Excel, va al macro o a las equivalencias; si es de **un partido** y aparece como cambio detectado, se resuelve en la validación. Antes de cargar una equivalencia, verificar que el nombre "erróneo" no sea el nombre legítimo de otro partido.

### Controles (tests dbt)

- `warn_cambios_nombre_pendientes` (warn): cambios sin decisión.
- `assert_homologacion_huerfana` (warn): un ACEPTADO que ya no coincide con ningún cambio detectado (hay que revisarlo de nuevo).
- `warn_correccion_no_aplicada` (warn): un ERROR_CARGA cuyo cambio sigue apareciendo.
- Grano único en la detección, en la tabla oficial y en la auditoría; valores válidos de `motivo`.

La carpeta `revision/` (Excel de trabajo) no se commitea.

> **Correcciones:** hay dos caminos según el tipo de error.
> - **Error de `nro_distrito`** (número que no coincide con la identidad del partido): se agrega una fila al seed `dbt/seeds/correcciones_distrito.csv` y se corre `dbt build`. No se toca el raw; la corrección queda versionada.
> - **Error de nombre:** según el alcance, ver la tabla de herramientas en *Flujo de cambios de nombre* (macro `limpiar_nombre`, seed `equivalencias_nombre` o `validar.py`), y después `dbt build`.
> - **Corte defectuoso / archivo corregido** (reprocesar un mes ya cargado): se corre `python reprocesar.py --fecha DD-MM-YYYY`, que borra el blob del bucket y las filas de raw de ese `snapshot_date` (pide confirmación). Después se pone el Excel corregido en `data/` y se corre `run_cierre.ps1`: el pipeline detecta el mes faltante, lo recarga y reconstruye la historia. El pipeline solo agrega meses nuevos; no pisa los existentes, por eso primero hay que eliminar el corte.

## Fuente

Registro Nacional de Agrupaciones Políticas — Argentina
Publicación mensual en Excel. ~750 registros por snapshot

## Autor

Andrés Miño — andresminio@gmail.com
