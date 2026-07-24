import storage
import parser
import bigquery_loader as loader


def main():

    # Asegura que exista el dataset antes de cargar.
    loader.ensure_dataset()

    # Solo nombres validos, ordenados cronologicamente por la fecha
    # del nombre del archivo (no alfabeticamente).
    archivos = sorted(
        (a for a in storage.list_excel_files() if parser.is_valid_filename(a)),
        key=parser.extract_snapshot_date,
    )

    ya_cargados = loader.get_loaded_files()

    total = len(archivos)

    for i, archivo in enumerate(archivos, start=1):

        if archivo in ya_cargados:
            print(f"[{i}/{total}] [SKIP] Ya fue cargado: {archivo}")
            continue

        print(f"[{i}/{total}] [LOAD] {archivo}")
        df = storage.read_excel(archivo)
        df = parser.parse_snapshot(df, archivo)
        loader.load_dataframe(df)


if __name__ == "__main__":
    main()
