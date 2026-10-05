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
    