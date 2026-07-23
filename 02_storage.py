import importlib
from io import BytesIO

import pandas as pd
from google.cloud import storage

# Los modulos empiezan con digito, asi que no se pueden importar
# con "import" normal. Se cargan con importlib.
config = importlib.import_module("01_config")
BUCKET = config.BUCKET


def get_storage_client():
    """Devuelve un cliente autenticado de Cloud Storage."""
    return storage.Client()


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
