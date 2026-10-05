{#
  Limpieza general de nombres de partido: quita anotaciones que se cuelan desde
  el Excel de la CNE. Se aplica en staging sobre el nombre ya normalizado
  (mayúsculas, sin acentos, espacios colapsados), antes de las correcciones
  puntuales del seed correcciones_nombre, que conservan la última palabra.

  Para sumar una regla nueva: agregar un regexp_replace a la cadena.

  Reglas:
    1. Todo lo que viene desde "*VER" hasta el final del nombre.
       Ej: "PARTIDO FRENTE GRANDE *VER COLUMNA"       -> "PARTIDO FRENTE GRANDE"
           "FRENTE RENOVADOR AUTENTICO *VER COLUMNA I" -> "FRENTE RENOVADOR AUTENTICO"
#}
{% macro limpiar_nombre(col) %}
  trim(
    regexp_replace({{ col }}, r'\s*\*\s*VER\b.*$', '')
  )
{% endmacro %}
