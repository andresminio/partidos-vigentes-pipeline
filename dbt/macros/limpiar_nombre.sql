{#
  Limpieza general de nombres de partido: corrige patrones de formato que se
  cuelan desde el Excel de origen. Se aplica en staging sobre el nombre ya
  normalizado (mayúsculas, sin acentos, espacios colapsados), antes del seed
  equivalencias_nombre (nombres exactos) y de las decisiones de la validación
  humana (ERROR_CARGA), que conservan la última palabra.

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
    4. Sin espacios del lado de adentro de los paréntesis.
       Ej: "... TRABAJO ( M.I.L.E.S.T.T.T )" -> "... TRABAJO (M.I.L.E.S.T.T.T)"
    5. Quita las anotaciones administrativas desde "ESPERAR" hasta el final
       (con o sin guion antes).
       Ej: "RED POR BUENOS AIRES -ESPERAR PLAZO REX-" -> "RED POR BUENOS AIRES"
           "... P.A.I.S ESPERAR RESOLUCION REX"       -> "... P.A.I.S"
#}
{% macro limpiar_nombre(col) %}
  trim(
    regexp_replace(
      regexp_replace(
        regexp_replace(
          regexp_replace(
            regexp_replace(
              regexp_replace({{ col }}, r'\s*\*\s*VER\b.*$', ''),
              r'\s*-?\s*\bESPERAR\b.*$', ''
            ),
            r'\s*-\s*', '-'
          ),
          r'["\x{201C}\x{201D}\x{201E}\x{00AB}\x{00BB}]', ''
        ),
        r'\(\s+', '('
      ),
      r'\s+\)', ')'
    )
  )
{% endmacro %}
