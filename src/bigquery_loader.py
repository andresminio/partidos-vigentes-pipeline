# IMPORTS
import pandas as pd
from google.cloud import bigquery
from google.cloud.exceptions import NotFound

from config import PROJECT_ID, DATASET, TABLE, LOCATION

# Columnas de metadatos con tipo propio; el resto se carga como STRING.
METADATA_SCHEMA = {
    "snapshot_date": "DATE",
    "_ingested_at": "TIMESTAMP",
    "_row_number": "INTEGER",
}

# Columnas obligatorias (mode REQUIRED). snapshot_date es la clave de
# particion, asi que BigQuery la exige NOT NULL.
REQUIRED_FIELDS = {"snapshot_date"}

# CLIENTE
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


# CONSULTAS

def get_loaded_dates() -> set:
    """
    Devuelve el conjunto de snapshot_date ya cargados en la tabla.

    La clave de un snapshot es su fecha, no el nombre del archivo: esto
    hace que un mismo mes no se duplique aunque llegue con distinto nombre,
    capitalizacion o separador.

    Si la tabla todavia no existe (primera corrida), devuelve un set vacio.
    """

    client = get_bigquery_client()

    try:
        client.get_table(_table_id())
    except NotFound:
        return set()

    query = f"""
        SELECT DISTINCT snapshot_date
        FROM `{_table_id()}`
    """

    return {row.snapshot_date for row in client.query(query).result()}


def get_loaded_snapshots() -> dict:
    """
    Devuelve {snapshot_date: max(_ingested_at)} de lo ya cargado.

    Sirve para detectar si el blob del bucket es mas nuevo que lo cargado
    (blob.updated > _ingested_at -> hay que reemplazar ese mes).

    Set vacio si la tabla todavia no existe.
    """
    client = get_bigquery_client()

    try:
        client.get_table(_table_id())
    except NotFound:
        return {}

    query = f"""
        SELECT snapshot_date, MAX(_ingested_at) AS ingested_at
        FROM `{_table_id()}`
        GROUP BY snapshot_date
    """

    return {row.snapshot_date: row.ingested_at for row in client.query(query).result()}


def delete_date(snapshot_date) -> None:
    """
    Borra del raw todas las filas de un snapshot_date. Se usa para reemplazar un
    mes cuando llega una version mas nueva del archivo.
    """
    client = get_bigquery_client()

    query = f"DELETE FROM `{_table_id()}` WHERE snapshot_date = @f"
    cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("f", "DATE", snapshot_date)]
    )
    client.query(query, job_config=cfg).result()


# CARGA

def _build_schema(df: pd.DataFrame) -> list[bigquery.SchemaField]:
    """
    Arma el schema: STRING para columnas de datos,
    tipos propios para las columnas de metadatos.
    """
    return [
        bigquery.SchemaField(
            column,
            METADATA_SCHEMA.get(column, "STRING"),
            mode="REQUIRED" if column in REQUIRED_FIELDS else "NULLABLE",
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
