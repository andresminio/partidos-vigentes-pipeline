from io import BytesIO

import pandas as pd
from google.cloud import storage

from config import BUCKET, PROJECT_ID


def get_storage_client():
    """Devuelve un cliente autenticado de Cloud Storage."""
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
