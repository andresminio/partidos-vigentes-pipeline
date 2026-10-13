"""
Validación humana de cambios de nombre (consola).

Muestra los cambios de nombre detectados (dbt: int_cambios_nombre) que todavía no
tienen decisión y, para cada uno, permite:
  (a) aceptar         -> el cambio es real; aparece en partidos_cambios_nombre.
  (e) error de carga  -> se pide el nombre correcto; staging lo usa para
                         reemplazar el nombre en los dos tramos involucrados
                         (desde el inicio del nombre anterior hasta el fin del
                         nombre nuevo) y el falso cambio deja de detectarse.
  (s) saltear / (q) salir.

Las decisiones se insertan en BigQuery (decisiones_cambios_nombre.registro), una
tabla CENTRALIZADA de solo inserción: la usan todas las personas que corren el
pipeline, nunca se edita ni se borra, y si se decide de nuevo un mismo cambio
prevalece la decisión más reciente. Quién decidió y cuándo se registran solos.

Los cambios CAMBIO_NACIONAL nunca se muestran: no se validan, siguen la
decisión de su nacional.

Al marcar un error de carga, ofrece agregarlo también al seed equivalencias_nombre
para que se corrija en todos los partidos y cierres futuros.

Uso (con el venv activo, desde src/):  python validar.py
Después de validar, correr dbt build para aplicar las decisiones.
"""

import csv
import re
import unicodedata
from pathlib import Path

from google.cloud import bigquery
from google.cloud.exceptions import NotFound

from config import (
    PROJECT_ID, LOCATION, DATASET_DBT, DATASET_DECISIONES, TABLE_DECISIONES,
)

TABLA_DECISIONES = f"{PROJECT_ID}.{DATASET_DECISIONES}.{TABLE_DECISIONES}"
TABLA_CAMBIOS = f"{PROJECT_ID}.{DATASET_DBT}.int_cambios_nombre"

SCHEMA = [
    bigquery.SchemaField("partido_key", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("fecha_cambio_nombre", "DATE", mode="REQUIRED"),
    bigquery.SchemaField("nombre_anterior", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("nombre_nuevo", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("decision", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("fundamento", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("nombre_correcto", "STRING"),
    bigquery.SchemaField("corregir_desde", "DATE"),
    bigquery.SchemaField("corregir_hasta", "DATE"),
    bigquery.SchemaField("decidido_por", "STRING", mode="REQUIRED"),
    bigquery.SchemaField("decidido_en", "TIMESTAMP", mode="REQUIRED"),
]


# BIGQUERY

def get_client() -> bigquery.Client:
    return bigquery.Client(project=PROJECT_ID, location=LOCATION)


def asegurar_tabla(client: bigquery.Client) -> None:
    """Crea el dataset y la tabla de decisiones si no existen (idempotente)."""
    dataset_id = f"{PROJECT_ID}.{DATASET_DECISIONES}"
    try:
        client.get_dataset(dataset_id)
    except NotFound:
        dataset = bigquery.Dataset(dataset_id)
        dataset.location = LOCATION
        client.create_dataset(dataset)
        print(f"Dataset creado: {dataset_id} ({LOCATION})")
    try:
        client.get_table(TABLA_DECISIONES)
    except NotFound:
        client.create_table(bigquery.Table(TABLA_DECISIONES, schema=SCHEMA))
        print(f"Tabla creada: {TABLA_DECISIONES}")


def leer_pendientes(client: bigquery.Client) -> list:
    """Cambios detectados sin decisión. Los CAMBIO_NACIONAL nunca se validan:
    siguen la decisión de su nacional."""
    query = f"""
        with decididos as (
            select distinct partido_key, fecha_cambio_nombre, nombre_anterior, nombre_nuevo
            from `{TABLA_DECISIONES}`
        ),
        cambios as (
            select * from `{TABLA_CAMBIOS}`
        )
        select c.*
        from cambios c
        left join decididos d
            on  d.partido_key         = c.partido_key
            and d.fecha_cambio_nombre = c.fecha_cambio_nombre
            and d.nombre_anterior     = c.nombre_anterior
            and d.nombre_nuevo        = c.nombre_nuevo
        where d.partido_key is null
          and c.origen_cambio != 'CAMBIO_NACIONAL'
        order by
            cast(c.nro_distrito as int64),
            cast(c.nro_partido as int64),
            c.orden desc,
            c.fecha_cambio_nombre
    """
    return [dict(r) for r in client.query(query).result()]


def registrar(client: bigquery.Client, cambio: dict, decision: str, fundamento: str,
              nombre_correcto=None, corregir_desde=None, corregir_hasta=None) -> None:
    """Inserta una decisión. Quién y cuándo los completa BigQuery."""
    query = f"""
        insert into `{TABLA_DECISIONES}` (
            partido_key, fecha_cambio_nombre, nombre_anterior, nombre_nuevo,
            decision, fundamento, nombre_correcto, corregir_desde, corregir_hasta,
            decidido_por, decidido_en
        )
        values (
            @partido_key, @fecha_cambio_nombre, @nombre_anterior, @nombre_nuevo,
            @decision, @fundamento, @nombre_correcto, @corregir_desde, @corregir_hasta,
            session_user(), current_timestamp()
        )
    """
    params = [
        bigquery.ScalarQueryParameter("partido_key", "STRING", cambio["partido_key"]),
        bigquery.ScalarQueryParameter("fecha_cambio_nombre", "DATE", cambio["fecha_cambio_nombre"]),
        bigquery.ScalarQueryParameter("nombre_anterior", "STRING", cambio["nombre_anterior"]),
        bigquery.ScalarQueryParameter("nombre_nuevo", "STRING", cambio["nombre_nuevo"]),
        bigquery.ScalarQueryParameter("decision", "STRING", decision),
        bigquery.ScalarQueryParameter("fundamento", "STRING", fundamento),
        bigquery.ScalarQueryParameter("nombre_correcto", "STRING", nombre_correcto),
        bigquery.ScalarQueryParameter("corregir_desde", "DATE", corregir_desde),
        bigquery.ScalarQueryParameter("corregir_hasta", "DATE", corregir_hasta),
    ]
    client.query(query, job_config=bigquery.QueryJobConfig(query_parameters=params)).result()


# ENTRADA POR CONSOLA

def normalizar_nombre(texto: str) -> str:
    """Igual que staging: mayúsculas, sin acentos (preserva la Ñ), espacios colapsados."""
    texto = texto.replace("ñ", "").replace("Ñ", "")
    texto = unicodedata.normalize("NFD", texto)
    texto = "".join(ch for ch in texto if unicodedata.category(ch) != "Mn")
    texto = texto.replace("", "ñ").replace("", "Ñ")
    return re.sub(r"\s+", " ", texto).strip().upper()


def preguntar(texto: str, opciones: set) -> str:
    while True:
        r = input(texto).strip().lower()
        if r in opciones:
            return r
        print(f"  Opción inválida. Elegí una de: {', '.join(sorted(opciones))}")


def preguntar_texto(texto: str, default: str = "") -> str:
    while True:
        r = input(texto).strip()
        if r:
            return r
        if default:
            return default
        print("  Es obligatorio.")


def fecha(d) -> str:
    return d.strftime("%d-%m-%Y")


def mostrar(i: int, total: int, c: dict) -> None:
    print()
    print(f"[{i}/{total}] {c['partido_key']}  {c['distrito']}   "
          f"({c['origen_cambio']})")
    print(f"  ANTERIOR: {c['nombre_anterior']}")
    print(f"            desde {fecha(c['nombre_anterior_desde'])} hasta {fecha(c['nombre_anterior_hasta'])}")
    print(f"  NUEVO:    {c['nombre_nuevo']}")
    print(f"            desde {fecha(c['fecha_cambio_nombre'])} hasta {fecha(c['nombre_nuevo_hasta'])}")


# EQUIVALENCIAS (seed de dbt, corrección masiva)

SEED_EQUIVALENCIAS = Path(__file__).resolve().parent.parent / "dbt" / "seeds" / "equivalencias_nombre.csv"
TABLA_PARTIDOS = f"{PROJECT_ID}.{DATASET_DBT}.int_partidos"


def leer_equivalencias() -> dict:
    """nombre_variante -> nombre_canonico, tal como están en el seed."""
    with open(SEED_EQUIVALENCIAS, encoding="utf-8", newline="") as f:
        return {r["nombre_variante"]: r["nombre_canonico"] for r in csv.DictReader(f)}


def otros_partidos_con_nombre(client: bigquery.Client, nombre: str, cambio: dict) -> list:
    """Partidos de OTRO número que usan ese nombre: una equivalencia los cambiaría también.
    Los del mismo número (el nacional y sus distritos) se excluyen: comparten nombre."""
    query = f"""
        select distinct partido_key
        from `{TABLA_PARTIDOS}`
        where partido_politico = @nombre
          and partido_key != @partido_key
          and nro_partido != @nro_partido
        order by partido_key
        limit 20
    """
    params = [
        bigquery.ScalarQueryParameter("nombre", "STRING", nombre),
        bigquery.ScalarQueryParameter("partido_key", "STRING", cambio["partido_key"]),
        bigquery.ScalarQueryParameter("nro_partido", "STRING", cambio["nro_partido"]),
    ]
    job = client.query(query, job_config=bigquery.QueryJobConfig(query_parameters=params))
    return [r["partido_key"] for r in job.result()]


def agregar_equivalencias(client: bigquery.Client, cambio: dict, nombre_correcto: str) -> int:
    """Agrega al seed el nombre anterior y/o nuevo que difieran del correcto, como
    variantes del correcto. Devuelve cuántas filas agregó."""
    existentes = leer_equivalencias()
    variantes = []
    for n in (cambio["nombre_anterior"], cambio["nombre_nuevo"]):
        if n != nombre_correcto and n not in variantes:
            variantes.append(n)

    nuevas = []
    for v in variantes:
        if v in existentes:
            if existentes[v] == nombre_correcto:
                print(f"    = ya existe: {v} -> {nombre_correcto}")
            else:
                print(f"    ! no se agrega: {v} ya está en el seed como -> {existentes[v]}")
            continue
        otros = otros_partidos_con_nombre(client, v, cambio)
        if otros:
            print(f"    ! '{v}' es también el nombre de otros partidos: {', '.join(otros)}")
            print("      Una equivalencia los cambiaría también a ellos.")
            if preguntar("      ¿Agregarla igual? (s/n): ", {"s", "n"}) == "n":
                continue
        nuevas.append([v, nombre_correcto])

    if not nuevas:
        return 0

    contenido = SEED_EQUIVALENCIAS.read_text(encoding="utf-8")
    with open(SEED_EQUIVALENCIAS, "a", encoding="utf-8", newline="") as f:
        if contenido and not contenido.endswith("\n"):
            f.write("\n")
        csv.writer(f, lineterminator="\n").writerows(nuevas)
    for v, canon in nuevas:
        print(f"    + {v} -> {canon}")
    print("  OK: agregado a dbt/seeds/equivalencias_nombre.csv")
    return len(nuevas)


# MAIN

def consola(client: bigquery.Client) -> None:
    try:
        pendientes = leer_pendientes(client)
    except NotFound:
        print(f"No existe {TABLA_CAMBIOS}. Corré dbt build primero y volvé a ejecutar validar.py.")
        return

    total = len(pendientes)
    print(f"Cambios de nombre pendientes de validación: {total}")
    if not total:
        return

    aceptados = errores = equivalencias = 0
    try:
        for i, c in enumerate(pendientes, 1):
            mostrar(i, total, c)
            op = preguntar("  (a) aceptar  (e) error de carga  (s) saltear  (q) salir: ",
                           {"a", "e", "s", "q"})
            if op == "q":
                break
            if op == "s":
                continue

            if op == "a":
                fundamento = preguntar_texto("  Fundamento: ")
                if preguntar("  Confirmás ACEPTADO? (s/n): ", {"s", "n"}) == "n":
                    print("  No registrado.")
                    continue
                registrar(client, c, "ACEPTADO", fundamento)
                aceptados += 1
                print("  OK: registrado como ACEPTADO.")

            else:  # error de carga
                nombre_correcto = normalizar_nombre(preguntar_texto("  Nombre correcto: "))
                fundamento = preguntar_texto("  Fundamento: ")
                desde, hasta = c["nombre_anterior_desde"], c["nombre_nuevo_hasta"]
                print(f"  Se reemplazará el nombre por '{nombre_correcto}' "
                      f"de {fecha(desde)} a {fecha(hasta)}.")
                if preguntar("  Confirmás ERROR_CARGA? (s/n): ", {"s", "n"}) == "n":
                    print("  No registrado.")
                    continue
                registrar(client, c, "ERROR_CARGA", fundamento,
                          nombre_correcto=nombre_correcto,
                          corregir_desde=desde, corregir_hasta=hasta)
                errores += 1
                print("  OK: registrado como ERROR_CARGA.")
                if preguntar("  ¿Queres agregarlo también a equivalencias_nombre para que aplique "
                             "a todos los partidos y cierres con el mismo error en el futuro? (s/n): ",
                             {"s", "n"}) == "s":
                    equivalencias += agregar_equivalencias(client, c, nombre_correcto)
    except (KeyboardInterrupt, EOFError):
        print("\nInterrumpido. Lo registrado hasta acá quedó guardado.")

    print()
    print(f"Registrados: {aceptados} aceptados, {errores} errores de carga, "
          f"{equivalencias} equivalencias nuevas.")
    if aceptados or errores:
        print("Para aplicarlos: cd ..\\dbt ; dbt build")
    if equivalencias:
        print("Las equivalencias nuevas están en dbt/seeds/equivalencias_nombre.csv (git): "
              "commitealas y subilas para que apliquen en todas las máquinas.")


def main():
    client = get_client()
    asegurar_tabla(client)
    try:
        consola(client)
    except NotFound:
        print(f"No existe {TABLA_CAMBIOS}. Corré dbt build primero y volvé a ejecutar validar.py.")


if __name__ == "__main__":
    main()
