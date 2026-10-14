from functools import lru_cache
from io import BytesIO

import pandas as pd
from google.cloud import storage

from config import BUCKET, PROJECT_ID


@lru_cache(maxsize=1)
def get_storage_client():
    """
    Devuelve un cliente autenticado de Cloud Storage.

    Se crea una sola vez por corrida y se reutiliza: cada cliente nuevo pide
    credenciales (impersonación), y eso es lo que más tarda.
    """
    return storage.Client(project=PROJECT_ID)


def list_files() -> list[str]:
    """Lista todos los archivos del bucket."""
    client = get_storage_client()
    bucket = client.bucket(BUCKET)

    return sorted(blob.name for blob in bucket.list_blobs())


def list_excel_files() -> list[str]:
    """Lista solo los archivos .xlsx del bucket."""
    return [
        name
        for name in list_files()
        if name.lower().endswith(".xlsx")
    ]


def read_excel(blob_name: str) -> pd.DataFrame:
    """
    Lee un Excel directamente desde Cloud Storage
    y devuelve un DataFrame.
    """
    client = get_storage_client()
    bucket = client.bucket(BUCKET)

    blob = bucket.blob(blob_name)

    excel_bytes = blob.download_as_bytes()

    return pd.read_excel(BytesIO(excel_bytes), dtype=str)


def upload_file(local_path, blob_name: str) -> None:
    """
    Sube un archivo local al bucket con el nombre indicado.
    """
    client = get_storage_client()
    bucket = client.bucket(BUCKET)

    blob = bucket.blob(blob_name)

    blob.upload_from_filename(str(local_path))


def listar_blobs() -> dict:
    """
    Devuelve {nombre: blob} de todo el bucket, con una sola consulta.

    Cada blob ya trae su metadata (`md5_hash`, `updated`): se usa para decidir
    si re-subir (md5 distinto) o reprocesar (updated mas nuevo) sin consultar
    archivo por archivo.
    """
    client = get_storage_client()
    bucket = client.bucket(BUCKET)

    return {blob.name: blob for blob in bucket.list_blobs()}
