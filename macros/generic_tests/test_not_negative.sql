{#
    Test generique "maison" : reutilisable sur N'IMPORTE QUELLE colonne
    numerique de n'importe quel modele, juste en le referencant par son
    nom dans un fichier YAML (comme unique/not_null/accepted_values).
    Un test generique dbt est simplement une macro definie avec
    {% test <nom>(model, column_name, ...) %} qui SELECT les lignes en
    ECHEC (le test echoue si la requete retourne >= 1 ligne).
#}
{% test not_negative(model, column_name) %}

select *
from {{ model }}
where {{ column_name }} < 0

{% endtest %}
