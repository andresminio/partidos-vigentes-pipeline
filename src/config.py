from pathlib import Path

PROJECT_ID = "partidos-vigentes-pipeline"
BUCKET = "partidos-vigentes-raw"
DATASET = "raw"
TABLE = "partidos_snapshot"

# Region del dataset de BigQuery
LOCATION = "US"

# Carpeta local donde caen los Excel antes de subir al bucket.
# Se resuelve relativa a la raiz del repo (un nivel arriba de src/).
DATA_DIR = Path(__file__).resolve().parent.parent / "data"

# Solo se ingestan archivos que matcheen este patron de nombre.
# Ej: "Partidos Vigentes al 31_01_2026.xlsx"
FILENAME_PATTERN = r"^Partidos Vigentes al \d{2}_\d{2}_\d{4}\.xlsx$"
