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

# Solo se ingestan archivos locales que matcheen este patron de nombre.
# - "Politicos" es opcional: "Partidos Vigentes" o "Partidos Politicos Vigentes".
# - "al" es opcional: la CNE a veces lo omite ("... Vigentes 30-11-2025").
# - La fecha acepta guion bajo o guion medio (DD_MM_YYYY o DD-MM-YYYY), la CNE usa ambos.
# - La capitalizacion y los acentos son libres (IGNORECASE en parser; el acento se cubre con [ií]).
# Ej: "Partidos Vigentes al 31_01_2026.xlsx" o "Partidos Politicos Vigentes 30-11-2025.xlsx"
FILENAME_PATTERN = r"^Partidos (Pol[ií]ticos )?Vigentes (al )?\d{2}[_-]\d{2}[_-]\d{4}\.xlsx$"
