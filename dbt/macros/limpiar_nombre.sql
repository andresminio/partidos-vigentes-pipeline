{#
  Limpieza general de nombres de partido: corrige patrones de formato que se
  cuelan desde el Excel de la CNE. Se aplica en staging sobre el nombre ya
  normalizado (mayúsculas, sin acentos, espacios colapsados), antes del seed
  equivalencias_nombre (nombres exactos) y de las correcciones puntuales del seed
  correcciones_nombre, que conservan la última palabra.

  Para sumar una regla nueva: agregar un regexp_replace a la cadena.

  Reglas:
    1. Quita todo lo que viene desde "*VER" hasta el final del nombre.
       Ej: "PARTIDO FRENTE GRANDE *VER COLUMNA"       -> "PARTIDO FRENTE GRANDE"
           "FRENTE RENOVADOR AUTENTICO *VER COLUMNA I" -> "FRENTE RENOVADOR AUTENTICO"
    2. Guion sin espacios alrededor.
       Ej: "PRO - PROPUESTA REPUBLICANA" -> "PRO-PROPUESTA REPUBLICANA"
           "... Y CULTURAL -PROYECTO"    -> "... Y CULTURAL-PROYECTO"
    3. Quita las comillas dobles (rectas y tipográficas) en cualquier parte.
       Ej: '"MOVIMIENTO ... (M.I.L.E.S.T.T.T.)"' -> 'MOVIMIENTO ... (M.I.L.E.S.T.T.T.)'
#}
{% macro limpiar_nombre(col) %}
  trim(
    regexp_replace(
      regexp_replace(
        regexp_replace({{ col }}, r'\s*\*\s*VER\b.*$', ''),
        r'\s*-\s*', '-'
      ),
      r'["\x{201C}\x{201D}\x{201E}\x{00AB}\x{00BB}]', ''
    )
  )
{% endmacro %}
