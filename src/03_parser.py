# IMPORTS
import importlib
import re
import unicodedata
from datetime import datetime, timezone

import pandas as pd

# Modulo con prefijo numerico: se carga con importlib.
config = importlib.import_module("01_config")
FILENAME_PATTERN = config.FILENAME_PATTERN


# CONSTANTES

DATE_PATTERN = re.compile(r"(\d{2})_(\d{2})_(\d{4})")
NAME_PATTERN = re.compile(FILENAME_PATTERN)


# VALIDACION DE NOMBRE


def is_valid_filename(filename: str) -> bool:
    """
    Indica si el nombre del archivo cumple el patron esperado.

    Ejemplo valido:
        Partidos Vigentes al 31_01_2026.xlsx
    """
    return NAME_PATTERN.match(filename) is not None


# EXTRACCION DE METADATOS


def extract_snapshot_date(filename: str):
    """
    Extrae la fecha del nombre del archivo.

    Ejemplo:
        Partidos Vigentes al 31_01_2026.xlsx
    """

    match = DATE_PATTERN.search(filename)

    if match is None:
        raise ValueError(
            f"No se encontro una fecha valida en '{filename}'."
        )

    day, month, year = match.groups()

    return datetime.strptime(
        f"{year}-{month}-{day}",
        "%Y-%m-%d"
    ).date()


# NORMALIZACION


def _strip_accents(text: str) -> str:
    """Quita acentos y diacriticos (a, e, n, ...)."""
    normalized = unicodedata.normalize("NFKD", text)
    return "".join(
        char for char in normalized
        if not unicodedata.combining(char)
    )


def normalize_column_name(column: str) -> str:
    """
    Convierte un nombre de columna a snake_case sin acentos.
    """

    column = _strip_accents(column)
    column = column.strip().lower()
    column = column.replace(" ", "_")
    column = re.sub(r"[^\w]", "", column)

    return column


# TRANSFORMACION DEL DATAFRAME


def parse_snapshot(
    df: pd.DataFrame,
    filename: str
) -> pd.DataFrame:
    """
    Prepara el DataFrame para la capa RAW.
    """

    snapshot_date = extract_snapshot_date(filename)

    # Normalizar nombres de columnas
    df.columns = [
        normalize_column_name(column)
        for column in df.columns
    ]

    # Normalizar valores
    df = df.fillna("")
    df = df.astype(str)
    df = df.apply(lambda column: column.str.strip())

    # Agregar metadatos
    df["snapshot_date"] = snapshot_date
    df["_source_file"] = filename
    df["_ingested_at"] = datetime.now(timezone.utc)
    df["_row_number"] = range(1, len(df) + 1)

    return df
