{#
    Surcharge du generate_schema_name par defaut de dbt.
    Comportement par defaut de dbt : {{ target.schema }}_{{ custom_schema }}
    quel que soit le target -> en dev, chaque +schema de dbt_project.yml
    (staging, marts, seeds, ...) cree un schema distinct, ce qui est
    voulu ici a but pedagogique. Ce snippet est neanmoins LE standard
    recommande par dbt Labs : il evite l'explosion de schemas en dev
    quand plusieurs devs bossent sur la meme base, tout en gardant des
    schemas propres (staging/marts/...) en prod. Voir
    bootcamp/04-jinja-macros-avancees.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}

    {%- set default_schema = target.schema -%}
    {%- if custom_schema_name is none -%}

        {{ default_schema }}

    {%- else -%}

        {%- if target.name == 'prod' -%}

            {{ custom_schema_name | trim }}

        {%- else -%}

            {{ default_schema }}_{{ custom_schema_name | trim }}

        {%- endif -%}

    {%- endif -%}

{%- endmacro %}
