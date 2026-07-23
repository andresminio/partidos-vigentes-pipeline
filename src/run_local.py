"""
Runner LOCAL de prueba.

Lee los Excel de la carpeta data/ (en vez del bucket de Cloud Storage)
y los carga a BigQuery. Sirve para validar la conexion y la carga sin
tener que subir nada al bucket todavia.

Uso (parado en la raiz del proyecto):
    python src/run_local.py
"""

import importlib
import glob
import os

import pandas as pd

# Modulos con prefijo numerico: se cargan con importlib.
parser = importlib.import_module("03_parser")
loader = importlib.import_module("04_bigquery_loader")

# data/ esta un nivel arriba de src/, sin importar desde donde se ejecute.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(SCRIPT_DIR, "..", "data")


def main():

    # Asegura que exista el dataset antes de cargar.
    loader.ensure_dataset()

    rutas = glob.glob(os.path.join(DATA_DIR, "*.xlsx"))

    archivos = sorted(
        (
            os.path.basename(ruta)
            for ruta in rutas
            if parser.is_valid_filename(os.path.basename(ruta))
        ),
        key=parser.extract_snapshot_date,
    )

    ya_cargados = loader.get_loaded_files()
    total = len(archivos)

    if total == 0:
        print(f"No se encontraron Excel validos en {DATA_DIR}")
        return

    for i, archivo in enumerate(archivos, start=1):

        if archivo in ya_cargados:
            print(f"[{i}/{total}] [SKIP] Ya fue cargado: {archivo}")
            continue

        print(f"[{i}/{total}] [LOAD] {archivo}")
        df = pd.read_excel(os.path.join(DATA_DIR, archivo), dtype=str)
        df = parser.parse_snapshot(df, archivo)
        loader.load_dataframe(df)


if __name__ == "__main__":
    main()
