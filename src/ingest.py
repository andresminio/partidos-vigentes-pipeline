from datetime import datetime, timezone

import storage
import parser
import bigquery_loader as loader


def main():

    # Asegura que exista el dataset antes de cargar.
    loader.ensure_dataset()

    # Blobs del bucket con una fecha reconocible en el nombre, ordenados
    # cronologicamente. Lo unico que importa del nombre es la fecha.
    blobs = []
    for nombre in storage.list_excel_files():
        try:
            blobs.append((parser.extract_snapshot_date(nombre), nombre))
        except ValueError:
            continue

    blobs.sort(key=lambda par: par[0])

    # {snapshot_date: max(_ingested_at)} de lo ya cargado. Sirve para detectar
    # si un blob es mas nuevo que lo cargado (hay que reemplazar ese mes).
    cargadas = loader.get_loaded_snapshots()

    total = len(blobs)

    for i, (fecha, nombre) in enumerate(blobs, start=1):

        ingested_at = cargadas.get(fecha)
        meta = storage.get_blob_meta(nombre)
        blob_updated = meta.updated if meta is not None else None

        if ingested_at is None:
            # Mes nuevo: se carga.
            accion = "LOAD"
        elif blob_updated is not None and blob_updated > ingested_at:
            # El blob se re-subio despues de la ultima carga (actualizacion del
            # mismo mes) -> se borra el mes y se recarga la version nueva.
            accion = "REEMPLAZO"
            loader.delete_date(fecha)
        else:
            print(f"[{i}/{total}] [SKIP] ya cargado y sin cambios: {nombre} ({fecha})")
            continue

        print(f"[{i}/{total}] [{accion}] {nombre} ({fecha})")
        df = storage.read_excel(nombre)
        df = parser.parse_snapshot(df, nombre)
        loader.load_dataframe(df)

        # Marca la fecha como recien cargada para que otro blob de la misma fecha
        # en esta corrida no la vuelva a procesar.
        cargadas[fecha] = datetime.now(timezone.utc)


if __name__ == "__main__":
    main()
