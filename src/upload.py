import base64
import hashlib

import storage
import parser
from config import DATA_DIR
#comentario de prueba


def _local_md5(path) -> str:
    """MD5 del archivo local en base64, mismo formato que blob.md5_hash de GCS."""
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return base64.b64encode(h.digest()).decode()


def latest_local_por_fecha() -> dict:
    """
    Por cada snapshot_date, el Path del archivo local mas reciente (por mtime).

    Admite variantes del mismo mes (' (2)', '-copia', etc.): si hay mas de un
    archivo para la misma fecha, gana el de modificacion mas reciente.
    """
    elegido = {}

    for path in DATA_DIR.glob("*.xlsx"):
        if not parser.is_valid_filename(path.name):
            continue
        try:
            fecha = parser.extract_snapshot_date(path.name)
        except ValueError:
            continue

        actual = elegido.get(fecha)
        if actual is None or path.stat().st_mtime > actual.stat().st_mtime:
            elegido[fecha] = path

    return elegido


def main():

    elegidos = latest_local_por_fecha()

    if not elegidos:
        print(f"No hay archivos validos en {DATA_DIR}.")
        return

    total = len(elegidos)

    for i, (fecha, path) in enumerate(sorted(elegidos.items()), start=1):

        # Se sube con nombre estandar derivado de la fecha (un blob por fecha).
        blob = parser.canonical_name(fecha)
        meta = storage.get_blob_meta(blob)

        # Idempotencia por contenido: si el blob existe y el md5 coincide, no se
        # re-sube (evita disparar un reprocesamiento al pedo en el ingest).
        if meta is not None and meta.md5_hash == _local_md5(path):
            print(f"[{i}/{total}] [SKIP] sin cambios: {path.name} -> {blob} ({fecha})")
            continue

        accion = "REEMPLAZO" if meta is not None else "UPLOAD"
        print(f"[{i}/{total}] [{accion}] {path.name} -> {blob} ({fecha})")
        storage.upload_file(path, blob)


if __name__ == "__main__":
    main()
