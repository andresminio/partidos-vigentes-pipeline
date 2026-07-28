import storage
import parser
from config import DATA_DIR


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


def main():

    # Archivos validos que estan en la carpeta local.
    locales = list_local_excel_files()

    # Lo que ya vive en el bucket, para subir solo lo nuevo.
    en_bucket = set(storage.list_files())

    total = len(locales)

    if total == 0:
        print(f"No hay archivos validos en {DATA_DIR}.")
        return

    for i, nombre in enumerate(locales, start=1):

        if nombre in en_bucket:
            print(f"[{i}/{total}] [SKIP] Ya esta en el bucket: {nombre}")
            continue

        print(f"[{i}/{total}] [UPLOAD] {nombre}")
        storage.upload_file(DATA_DIR / nombre, nombre)


if __name__ == "__main__":
    main()
