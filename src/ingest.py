import storage
import parser
import bigquery_loader as loader


def main():

    # Asegura que exista el dataset antes de cargar.
    loader.ensure_dataset()

    # Blobs del bucket con una fecha reconocible en el nombre, ordenados
    # cronologicamente. No se valida el formato completo del nombre: el
    # bucket puede tener nombres estandar (partidos_vigentes_...) o los
    # historicos (Partidos Vigentes al ...); lo unico que importa es la fecha.
    blobs = []
    for nombre in storage.list_excel_files():
        try:
            blobs.append((parser.extract_snapshot_date(nombre), nombre))
        except ValueError:
            continue

    blobs.sort(key=lambda par: par[0])

    # Deduplicacion por snapshot_date (no por nombre de archivo).
    fechas_cargadas = loader.get_loaded_dates()

    total = len(blobs)

    for i, (fecha, nombre) in enumerate(blobs, start=1):

        if fecha in fechas_cargadas:
            print(f"[{i}/{total}] [SKIP] snapshot ya cargado: {nombre} ({fecha})")
            continue

        print(f"[{i}/{total}] [LOAD] {nombre} ({fecha})")
        df = storage.read_excel(nombre)
        df = parser.parse_snapshot(df, nombre)
        loader.load_dataframe(df)

        # Marca la fecha para no recargarla si otro blob de la misma corrida
        # comparte snapshot_date.
        fechas_cargadas.add(fecha)


if __name__ == "__main__":
    main()
