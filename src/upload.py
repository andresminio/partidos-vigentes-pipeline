import storage
import parser
from config import DATA_DIR
#comentario de prueba
def list_local_excel_files() -> list[str]:
    """
    Nombres de los .xlsx validos que hay en la carpeta local,
    ordenados cronologicamente por la fecha del nombre.
    """
    return sorted(
        (
            path.name
            for path in DATA_DIR.glob("*.xlsx")
            if parser.is_valid_filename(path.name)
        ),
        key=parser.extract_snapshot_date,
    )


def snapshot_dates_in_bucket() -> set:
    """
    Fechas de snapshot ya presentes en el bucket, deducidas del nombre
    de cada blob. Ignora los que no tengan una fecha reconocible.
    """
    fechas = set()

    for nombre in storage.list_files():
        try:
            fechas.add(parser.extract_snapshot_date(nombre))
        except ValueError:
            continue

    return fechas


def main():

    # Archivos validos en la carpeta local.
    locales = list_local_excel_files()

    # Fechas ya cargadas en el bucket (deduplicacion por snapshot_date,
    # no por nombre: distinto formato o capitalizacion no genera duplicados).
    en_bucket = snapshot_dates_in_bucket()

    total = len(locales)

    if total == 0:
        print(f"No hay archivos validos en {DATA_DIR}.")
        return

    for i, nombre in enumerate(locales, start=1):

        fecha = parser.extract_snapshot_date(nombre)

        if fecha in en_bucket:
            print(f"[{i}/{total}] [SKIP] snapshot ya en el bucket: {nombre} ({fecha})")
            continue

        # Se sube con nombre estandar derivado de la fecha.
        blob = parser.canonical_name(fecha)
        print(f"[{i}/{total}] [UPLOAD] {nombre} -> {blob}")
        storage.upload_file(DATA_DIR / nombre, blob)

        # Evita re-subir si dos archivos locales comparten la misma fecha.
        en_bucket.add(fecha)


if __name__ == "__main__":
    main()
