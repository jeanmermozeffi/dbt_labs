{#
    Formate une colonne "cents" en chaine monetaire lisible.
    Exemple : pretty_currency('revenue_cents') -> '$1,234.50'
    Demontre la COMPOSITION de macros (celle-ci appelle cents_to_dollars)
    et un argument avec valeur par defaut.
#}
{% macro pretty_currency(cents_column, currency_symbol='$') %}
    ('{{ currency_symbol }}' || to_char({{ cents_to_dollars(cents_column) }}, 'FM999,999,990.00'))
{% endmacro %}
