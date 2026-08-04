{#
    Convertit une colonne de centimes (entiers) en unite monetaire
    decimale. Le cast explicite en numeric est indispensable : sur la
    plupart des entrepots, entier / entier fait une division entiere
    (2499 / 100 = 24, pas 24.99).
#}
{% macro cents_to_dollars(column_name, decimal_places=2) %}
    round(({{ column_name }})::numeric / 100, {{ decimal_places }})
{% endmacro %}
