{#
  Formatea el timestamp de ingesta (_ingested_at, TIMESTAMP UTC) como texto
  "DD/MM/AAAA HH:MM" en hora de Argentina. Es la "fecha de actualización del
  procedimiento": cuándo se procesó ese cierre. Vive en un macro para tener una
  sola definición reusada en los marts.
#}
{% macro actualizado(col) %}
  format_datetime('%d/%m/%Y %H:%M', datetime({{ col }}, 'America/Argentina/Buenos_Aires'))
{% endmacro %}
