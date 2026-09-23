"""
Elimina un corte (snapshot) para poder reprocesarlo: borra el/los blob(s) del
bucket y las filas de la capa raw con ese snapshot_date. Es destructivo, así que
muestra qué va a borrar y pide confirmación.

Después de correrlo:
  1) poné el Excel CORREGIDO en la carpeta data/
  2) corré run_cierre.ps1 (o upload.py + ingest.py + dbt build)
El pipeline detecta el mes faltante, lo recarga y dbt reconstruye la historia.

Uso:
    python reprocesar.py --fecha 31-08-2025         # pide confirmación
    python reprocesar.py --fecha 31-08-2025 --si    # sin confirmación
"""
import argparse
from datetime import datetime

from google.cloud import bigquery

import storage
import parser
import bigquery_loader as loader
from config import BUCKET, PROJECT_ID, DATASET, TABLE


def parse_fecha(texto: str):
    """Acepta DD-MM-YYYY o DD_MM_YYYY (los separadores que usa la CNE)."""
    for fmt in ("%d-%m-%Y", "%d_%m_%Y"):
        try:
            return datetime.strptime(texto, fmt).date()
        except ValueError:
            continue
    raise SystemExit(f"Fecha invalida: '{texto}'. Usar DD-MM-YYYY (ej. 31-08-2025).")


def blobs_de_fecha(fecha):
    """Blobs del bucket cuyo snapshot_date (deducido del nombre) coincide."""
    encontrados = []
    for nombre in storage.list_files():
        try:
            if parser.extract_snapshot_date(nombre) == fecha:
                encontrados.append(nombre)
        except ValueError:
            continue  # nombres sin fecha reconocible: se ignoran
    return encontrados


def contar_filas_bq(client, table_id, fecha):
    q = f"SELECT count(*) AS n FROM `{table_id}` WHERE snapshot_date = @f"
    cfg = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("f", "DATE", fecha)]
    )
    return list(client.query(q, job_config=cfg).result())[0].n


def main():
    ap = argparse.ArgumentParser(description="Elimina un corte para reprocesarlo.")
    ap.add_argument("--fecha", required=True,
                    help="Fecha del corte, DD-MM-YYYY (ej. 31-08-2025).")
    ap.add_argument("--si", action="store_true", help="No pedir confirmacion.")
    args = ap.parse_args()

    fecha = parse_fecha(args.fecha)
    table_id = f"{PROJECT_ID}.{DATASET}.{TABLE}"

    # Qué se va a borrar (se muestra antes de tocar nada).
    blobs = blobs_de_fecha(fecha)
    client = loader.get_bigquery_client()
    filas = contar_filas_bq(client, table_id, fecha)

    print(f"Corte a eliminar: {fecha:%d-%m-%Y}")
    print(f"  Bucket   ({BUCKET}): {len(blobs)} archivo(s) -> {blobs or '(ninguno)'}")
    print(f"  BigQuery ({table_id}): {filas} fila(s)")

    if not blobs and filas == 0:
        print("No hay nada para ese corte. Nada que hacer.")
        return

    if not args.si:
        resp = input("Confirmar borrado? (escribi 'si'): ").strip().lower()
        if resp != "si":
            print("Cancelado.")
            return

    # 1) Bucket
    sc = storage.get_storage_client()
    bucket = sc.bucket(BUCKET)
    for nombre in blobs:
        bucket.blob(nombre).delete()
        print(f"  [BUCKET] borrado: {nombre}")

    # 2) BigQuery (raw)
    if filas:
        q = f"DELETE FROM `{table_id}` WHERE snapshot_date = @f"
        cfg = bigquery.QueryJobConfig(
            query_parameters=[bigquery.ScalarQueryParameter("f", "DATE", fecha)]
        )
        client.query(q, job_config=cfg).result()
        print(f"  [BQ] borradas {filas} fila(s) de {table_id}")

    print()
    print("Corte eliminado. Ahora:")
    print("  1) Pone el Excel CORREGIDO en la carpeta data/.")
    print("  2) Corre run_cierre.ps1 (o upload.py + ingest.py + dbt build).")
    print("     El pipeline recarga el mes faltante y reconstruye la historia.")


if __name__ == "__main__":
    main()
