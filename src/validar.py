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

Los cambios HEREDADO_NACIONAL no se muestran si existe el cambio del nacional:
heredan su decisión.

Uso (con el venv activo, desde src/):
  python validar.py                      consola, de a un cambio (casos nuevos)
  python validar.py --exportar           Excel con todos los pendientes en revision/
  python validar.py --importar ARCHIVO   carga masiva de las decisiones del Excel
Después de validar, correr dbt build para aplicar las decisiones.
"""

import argparse
import re
import unicodedata
from datetime import date, datetime
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
    """Cambios detectados sin decisión, salvo heredados cuyo nacional cambió igual."""
    query = f"""
        with decididos as (
            select distinct partido_key, fecha_cambio_nombre, nombre_anterior, nombre_nuevo
            from `{TABLA_DECISIONES}`
        ),
        cambios as (
            select * from `{TABLA_CAMBIOS}`
        ),
        cambios_nacionales as (
            select nro_partido, fecha_cambio_nombre, nombre_nuevo
            from cambios
            where orden = 'NACIONAL'
        )
        select c.*
        from cambios c
        left join decididos d
            on  d.partido_key         = c.partido_key
            and d.fecha_cambio_nombre = c.fecha_cambio_nombre
            and d.nombre_anterior     = c.nombre_anterior
            and d.nombre_nuevo        = c.nombre_nuevo
        where d.partido_key is null
          and not (
              c.origen_cambio = 'HEREDADO_NACIONAL'
              and exists (
                  select 1 from cambios_nacionales n
                  where n.nro_partido         = c.nro_partido
                    and n.fecha_cambio_nombre = c.fecha_cambio_nombre
                    and n.nombre_nuevo        = c.nombre_nuevo
              )
          )
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
          f"({c['tipo_cambio']}, dist {c['distancia_edicion']}, {c['origen_cambio']})")
    print(f"  ANTERIOR: {c['nombre_anterior']}")
    print(f"            desde {fecha(c['nombre_anterior_desde'])} hasta {fecha(c['nombre_anterior_hasta'])}")
    print(f"  NUEVO:    {c['nombre_nuevo']}")
    print(f"            desde {fecha(c['fecha_cambio_nombre'])} hasta {fecha(c['nombre_nuevo_hasta'])}")


# CARGA MASIVA (EXCEL)

REVISION_DIR = Path(__file__).resolve().parent.parent / "revision"
FUNDAMENTO_DEFAULT = "Revisión masiva del histórico"
DECISIONES_VALIDAS = {"ACEPTADO", "ERROR_CARGA"}

# Columnas del Excel: (encabezado, clave del cambio o None si se completa a mano).
COLUMNAS_INFO = [
    ("partido_key", "partido_key"),
    ("distrito", "distrito"),
    ("tipo_cambio", "tipo_cambio"),
    ("distancia_edicion", "distancia_edicion"),
    ("origen_cambio", "origen_cambio"),
    ("nombre_anterior", "nombre_anterior"),
    ("anterior_desde", "nombre_anterior_desde"),
    ("anterior_hasta", "nombre_anterior_hasta"),
    ("nombre_nuevo", "nombre_nuevo"),
    ("fecha_cambio_nombre", "fecha_cambio_nombre"),
    ("nuevo_hasta", "nombre_nuevo_hasta"),
]
COLUMNAS_A_COMPLETAR = ["decision", "nombre_correcto", "fundamento"]


def clave(partido_key, fecha_cambio, nombre_anterior, nombre_nuevo) -> tuple:
    return (str(partido_key).strip(), fecha_cambio,
            str(nombre_anterior).strip(), str(nombre_nuevo).strip())


def a_fecha(v):
    """Lee una fecha del Excel: celda fecha o texto dd-mm-aaaa / aaaa-mm-dd."""
    if isinstance(v, datetime):
        return v.date()
    if isinstance(v, date):
        return v
    texto = str(v or "").strip()
    for fmt in ("%d-%m-%Y", "%Y-%m-%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(texto, fmt).date()
        except ValueError:
            pass
    return None


def exportar(client: bigquery.Client) -> None:
    from openpyxl import Workbook
    from openpyxl.styles import Font, PatternFill
    from openpyxl.worksheet.datavalidation import DataValidation

    pendientes = leer_pendientes(client)
    if not pendientes:
        print("No hay cambios pendientes de validación.")
        return

    wb = Workbook()
    ws = wb.active
    ws.title = "pendientes"
    encabezados = [h for h, _ in COLUMNAS_INFO] + COLUMNAS_A_COMPLETAR
    ws.append(encabezados)

    for c in pendientes:
        fila = []
        for _, k in COLUMNAS_INFO:
            v = c[k]
            fila.append(fecha(v) if isinstance(v, date) else v)
        ws.append(fila + ["", "", ""])

    # Formato: encabezado en negrita, columnas a completar resaltadas, filtros.
    amarillo = PatternFill("solid", fgColor="FFF2CC")
    for celda in ws[1]:
        celda.font = Font(bold=True)
    primera_editable = len(COLUMNAS_INFO) + 1
    for col in range(primera_editable, len(encabezados) + 1):
        ws.cell(row=1, column=col).fill = amarillo
    ws.freeze_panes = "B2"
    ws.auto_filter.ref = ws.dimensions
    anchos = {"nombre_anterior": 45, "nombre_nuevo": 45, "nombre_correcto": 45,
              "fundamento": 40, "distrito": 22}
    for idx, h in enumerate(encabezados, 1):
        ws.column_dimensions[ws.cell(row=1, column=idx).column_letter].width = anchos.get(h, 16)

    # Desplegable para la decisión.
    col_decision = ws.cell(row=1, column=primera_editable).column_letter
    dv = DataValidation(type="list", formula1='"ACEPTADO,ERROR_CARGA"', allow_blank=True)
    ws.add_data_validation(dv)
    dv.add(f"{col_decision}2:{col_decision}{len(pendientes) + 1}")

    REVISION_DIR.mkdir(exist_ok=True)
    salida = REVISION_DIR / f"pendientes_{date.today():%Y-%m-%d}.xlsx"
    wb.save(salida)
    print(f"Escrito {salida} ({len(pendientes)} cambios pendientes).")
    print("Completá decision (y nombre_correcto si es ERROR_CARGA), guardá y corré:")
    print(f"  python validar.py --importar \"{salida}\"")


def registrar_masivo(client: bigquery.Client, filas: list) -> None:
    """Inserta todas las decisiones en una sola operación."""
    structs = []
    for f in filas:
        c = f["cambio"]
        structs.append(bigquery.StructQueryParameter(
            None,
            bigquery.ScalarQueryParameter("partido_key", "STRING", c["partido_key"]),
            bigquery.ScalarQueryParameter("fecha_cambio_nombre", "DATE", c["fecha_cambio_nombre"]),
            bigquery.ScalarQueryParameter("nombre_anterior", "STRING", c["nombre_anterior"]),
            bigquery.ScalarQueryParameter("nombre_nuevo", "STRING", c["nombre_nuevo"]),
            bigquery.ScalarQueryParameter("decision", "STRING", f["decision"]),
            bigquery.ScalarQueryParameter("fundamento", "STRING", f["fundamento"]),
            bigquery.ScalarQueryParameter("nombre_correcto", "STRING", f["nombre_correcto"]),
            bigquery.ScalarQueryParameter("corregir_desde", "DATE", f["corregir_desde"]),
            bigquery.ScalarQueryParameter("corregir_hasta", "DATE", f["corregir_hasta"]),
        ))
    query = f"""
        insert into `{TABLA_DECISIONES}` (
            partido_key, fecha_cambio_nombre, nombre_anterior, nombre_nuevo,
            decision, fundamento, nombre_correcto, corregir_desde, corregir_hasta,
            decidido_por, decidido_en
        )
        select
            x.partido_key, x.fecha_cambio_nombre, x.nombre_anterior, x.nombre_nuevo,
            x.decision, x.fundamento, x.nombre_correcto, x.corregir_desde, x.corregir_hasta,
            session_user(), current_timestamp()
        from unnest(@filas) as x
    """
    params = [bigquery.ArrayQueryParameter("filas", "STRUCT", structs)]
    client.query(query, job_config=bigquery.QueryJobConfig(query_parameters=params)).result()


def importar(client: bigquery.Client, archivo: str) -> None:
    from openpyxl import load_workbook

    ruta = Path(archivo)
    if not ruta.exists():
        print(f"No existe el archivo: {ruta}")
        return

    ws = load_workbook(ruta, data_only=True).active
    filas_excel = list(ws.iter_rows(values_only=True))
    encabezados = [str(h).strip() if h is not None else "" for h in filas_excel[0]]
    faltan = [h for h in ["partido_key", "fecha_cambio_nombre", "nombre_anterior",
                          "nombre_nuevo"] + COLUMNAS_A_COMPLETAR if h not in encabezados]
    if faltan:
        print(f"Al Excel le faltan columnas: {', '.join(faltan)}")
        return
    pos = {h: i for i, h in enumerate(encabezados)}

    # Los pendientes actuales mandan: una fila del Excel solo se carga si su
    # cambio sigue pendiente (si alguien lo decidió en el medio, se saltea).
    pendientes = {
        clave(c["partido_key"], c["fecha_cambio_nombre"], c["nombre_anterior"], c["nombre_nuevo"]): c
        for c in leer_pendientes(client)
    }

    a_cargar, problemas = [], []
    sin_decidir = ya_decididos = 0
    vistos = set()
    for n, fila in enumerate(filas_excel[1:], start=2):
        val = lambda h: fila[pos[h]] if pos[h] < len(fila) else None
        decision = str(val("decision") or "").strip().upper()
        if not decision:
            sin_decidir += 1
            continue
        if decision not in DECISIONES_VALIDAS:
            problemas.append(f"fila {n}: decision inválida '{decision}'")
            continue

        k = clave(val("partido_key"), a_fecha(val("fecha_cambio_nombre")),
                  val("nombre_anterior"), val("nombre_nuevo"))
        if k in vistos:
            problemas.append(f"fila {n}: cambio repetido en el Excel")
            continue
        vistos.add(k)
        cambio = pendientes.get(k)
        if cambio is None:
            ya_decididos += 1
            continue

        fundamento = str(val("fundamento") or "").strip() or FUNDAMENTO_DEFAULT
        if decision == "ERROR_CARGA":
            nombre_correcto = normalizar_nombre(str(val("nombre_correcto") or ""))
            if not nombre_correcto:
                problemas.append(f"fila {n}: ERROR_CARGA sin nombre_correcto ({cambio['partido_key']})")
                continue
            a_cargar.append({
                "cambio": cambio, "decision": decision, "fundamento": fundamento,
                "nombre_correcto": nombre_correcto,
                "corregir_desde": cambio["nombre_anterior_desde"],
                "corregir_hasta": cambio["nombre_nuevo_hasta"],
            })
        else:
            a_cargar.append({
                "cambio": cambio, "decision": decision, "fundamento": fundamento,
                "nombre_correcto": None, "corregir_desde": None, "corregir_hasta": None,
            })

    aceptados = sum(1 for f in a_cargar if f["decision"] == "ACEPTADO")
    errores = len(a_cargar) - aceptados
    print(f"Archivo: {ruta}")
    print(f"  A cargar:       {aceptados} ACEPTADO, {errores} ERROR_CARGA")
    print(f"  Sin decidir:    {sin_decidir} (siguen pendientes)")
    print(f"  Ya no pendientes (decididos en el medio o editados en el Excel): {ya_decididos}")
    print(f"  Con problemas:  {len(problemas)}")
    for p in problemas:
        print(f"    - {p}")

    if not a_cargar:
        print("Nada para cargar.")
        return
    if preguntar(f"Confirmás la carga de {len(a_cargar)} decisiones? (s/n): ", {"s", "n"}) == "n":
        print("No se cargó nada.")
        return

    registrar_masivo(client, a_cargar)
    print(f"OK: {len(a_cargar)} decisiones registradas.")
    print("Para aplicarlas: cd ..\\dbt ; dbt build")


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

    aceptados = errores = 0
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
    except (KeyboardInterrupt, EOFError):
        print("\nInterrumpido. Lo registrado hasta acá quedó guardado.")

    print()
    print(f"Registrados: {aceptados} aceptados, {errores} errores de carga.")
    if aceptados or errores:
        print("Para aplicarlos: cd ..\\dbt ; dbt build")


def main():
    parser = argparse.ArgumentParser(description="Validación humana de cambios de nombre.")
    grupo = parser.add_mutually_exclusive_group()
    grupo.add_argument("--exportar", action="store_true",
                       help="genera un Excel con todos los pendientes en revision/")
    grupo.add_argument("--importar", metavar="ARCHIVO",
                       help="carga masiva de las decisiones completadas en el Excel")
    args = parser.parse_args()

    client = get_client()
    asegurar_tabla(client)
    try:
        if args.exportar:
            exportar(client)
        elif args.importar:
            importar(client, args.importar)
        else:
            consola(client)
    except NotFound:
        print(f"No existe {TABLA_CAMBIOS}. Corré dbt build primero y volvé a ejecutar validar.py.")


if __name__ == "__main__":
    main()
