{#
    Macro "compile-time query" : interroge l'entrepot AU MOMENT DE LA
    COMPILATION (via run_query) pour recuperer dynamiquement la liste
    des moyens de paiement distincts, au lieu de la coder en dur.
    Utilisee par int_payments_pivoted pour piloter dbt_utils.pivot.

    Le garde-fou `if execute` est indispensable : lors d'un `dbt parse`
    ou `dbt compile --no-populate-cache`, aucune requete ne part vers
    l'entrepot, donc `run_query` renverrait None et ferait planter la
    compilation sans cette protection.
#}
{% macro get_payment_methods() %}

    {% set payment_methods_query %}
        select distinct payment_method
        from {{ ref('stg_payments') }}
        order by 1
    {% endset %}

    {% if execute %}
        {% set results = run_query(payment_methods_query) %}
        {% set payment_methods = results.columns[0].values() %}
    {% else %}
        {% set payment_methods = [] %}
    {% endif %}

    {{ return(payment_methods) }}

{% endmacro %}
