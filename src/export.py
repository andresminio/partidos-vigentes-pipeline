from pathlib import Path

import pandas as pd
from google.cloud import bigquery

from config import PROJECT_ID, DATASET_DBT, LOCATION

# Mart de origen (foto actual del Registro).
TABLE = "partidos_vigentes"

# Columnas a publicar (técnico -> encabezado de presentación oficial), en orden.
COLUMNAS = {
    "id_partido": "ID PARTIDO",
    "orden": "ORDEN",
    "nro_distrito": "N° DISTRITO",
    "distrito": "DISTRITO",
    "nro_partido": "N° PARTIDO",
    "partido_politico": "PARTIDO POLITICO",
    "sigla": "SIGLA",
    "fecha_reconocimiento": "FECHA DE RECONOCIMIENTO",
    "integra_partido_nacional": "INTEGRA UN PARTIDO NACIONAL",
}

HOJA = "PARTIDOS POLÍTICOS VIGENTES"


def get_bigquery_client() -> bigquery.Client:
    return bigquery.Client(project=PROJECT_ID, location=LOCATION)


def main():
    client = get_bigquery_client()

    columnas = ", ".join(COLUMNAS)
    query = f"""
        select {columnas}, Actualizado
        from `{PROJECT_ID}.{DATASET_DBT}.{TABLE}`
        order by nro_distrito, orden, nro_partido
    """

    rows = [dict(r) for r in client.query(query).result()]
    if not rows:
        print("El mart partidos_vigentes está vacío; no se genera archivo.")
        return

    df = pd.DataFrame(rows)

    # Fecha de corte (del snapshot) para el nombre del archivo.
    fecha = max(df["Actualizado"])

    # Solo columnas de publicación, con los encabezados de presentación.
    df = df[list(COLUMNAS)].rename(columns=COLUMNAS)

    salida_dir = Path(__file__).resolve().parent.parent / "export"
    salida_dir.mkdir(exist_ok=True)
    salida = salida_dir / f"partidos_vigentes_{fecha:%d_%m_%Y}.xlsx"

    df.to_excel(salida, index=False, sheet_name=HOJA)
    print(f"Escrito {salida} ({len(df)} filas).")


if __name__ == "__main__":
    main()
