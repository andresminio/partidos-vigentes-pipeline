{#
  Quita los acentos/diacríticos de un texto, PRESERVANDO la ñ/Ñ.
  Técnica: descompone los caracteres (NFD) para separar la letra de su marca
  diacrítica y borra las marcas (\p{Mn}). La ñ también se descompondría a n + ~,
  así que antes se protege cambiándola por un centinela de la zona de uso privado
  (no aparece en nombres), y se restaura al final.
#}
{% macro sin_acentos(col) %}
  replace(replace(
    regexp_replace(
      normalize(replace(replace({{ col }}, 'ñ', ''), 'Ñ', ''), NFD),
      r'\p{Mn}', ''
    ),
  '', 'ñ'), '', 'Ñ')
{% endmacro %}
