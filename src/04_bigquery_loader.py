# =============================================================================
# IMPORTS
# =============================================================================

import importlib

import pandas as pd
from google.cloud import bigquery
from google.cloud.exceptions import NotFound

# Modulo con prefijo numerico: se carga con importlib.
config = importlib.import_module("01_config")
PROJECT_ID = config.PROJECT_ID
DATASET = config.DATASET
TABLE = config.TABLE
LOCATION = config.LOCATION


# Columnas de metadatos con tipo propio; el resto se carga como STRING.
METADATA_SCHEMA = {
    "snapshot_date": "DATE",
    "_ingested_at": "TIMESTAMP",
    "_row_number": "INTEGER",
}


# =============================================================================
# CLIENTE
# =============================================================================

def get_bigquery_client() -> bigquery.Client:
    """
    Devuelve un cliente autenticado de BigQuery.
    """

    return bigquery.Client(project=PROJECT_ID, location=LOCATION)


def _table_id() -> str:
    return f"{PROJECT_ID}.{DATASET}.{TABLE}"


def ensure_dataset() -> None:
    """
    Crea el dataset si no existe (el load crea la tabla, no el dataset).
    """

    client = get_bigquery_client()
    dataset_id = f"{PROJECT_ID}.{DATASET}"

    try:
        client.get_dataset(dataset_id)
    except NotFound:
        dataset = bigquery.Dataset(dataset_id)
        dataset.location = LOCATION
        client.create_dataset(dataset)
        print(f"Dataset creado: {dataset_id} ({LOCATION})")


# =============================================================================
# CONSULTAS
# =============================================================================

def get_loaded_files() -> set[str]:
    """
    Devuelve el conjunto de archivos ya cargados (segun _source_file).

    Si la tabla todavia no existe (primera corrida), devuelve un set vacio.
    """

    client = get_bigquery_client()

    try:
        client.get_table(_table_id())
    except NotFound:
        return set()

    query = f"""
        SELECT DISTINCT _source_file
        FROM `{_table_id()}`
    """

    return {row._source_file for row in client.query(query).result()}


def already_loaded(filename: str) -> bool:
    """
    Indica si el snapshot ya fue cargado.
    """

    return filename in get_loaded_files()


# =============================================================================
# CARGA
# =============================================================================

def _build_schema(df: pd.DataFrame) -> list[bigquery.SchemaField]:
    """
    Arma el schema: STRING para columnas de datos,
    tipos propios para las columnas de metadatos.
    """
    return [
        bigquery.SchemaField(
            column,
            METADATA_SCHEMA.get(column, "STRING"),
        )
        for column in df.columns
    ]


def load_dataframe(df: pd.DataFrame) -> None:
    """
    Inserta un DataFrame en la tabla RAW.

    - Schema explicito (datos como STRING).
    - Particion mensual por snapshot_date.
    - Clustering por distrito si la columna existe.
    - Permite agregar columnas nuevas sin romper (ALLOW_FIELD_ADDITION).
    """

    client = get_bigquery_client()

    clustering = ["distrito"] if "distrito" in df.columns else None

    job_config = bigquery.LoadJobConfig(
        schema=_build_schema(df),
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        schema_update_options=[
            bigquery.SchemaUpdateOption.ALLOW_FIELD_ADDITION
        ],
        time_partitioning=bigquery.TimePartitioning(
            type_=bigquery.TimePartitioningType.MONTH,
            field="snapshot_date",
        ),
        clustering_fields=clustering,
    )

    job = client.load_table_from_dataframe(
        dataframe=df,
        destination=_table_id(),
        job_config=job_config,
    )

    job.result()

    print(f"{len(df)} filas cargadas.")
