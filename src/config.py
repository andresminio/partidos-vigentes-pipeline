PROJECT_ID = "partidos-vigentes-pipeline"
BUCKET = "partidos-vigentes-raw"
DATASET = "raw"
TABLE = "partidos_snapshot"

# Region del dataset de BigQuery 
LOCATION = "US"

# Solo se ingestan archivos que matcheen este patron de nombre.
# Ej: "Partidos Vigentes al 31_01_2026.xlsx"
FILENAME_PATTERN = r"^Partidos Vigentes al \d{2}_\d{2}_\d{4}\.xlsx$"
