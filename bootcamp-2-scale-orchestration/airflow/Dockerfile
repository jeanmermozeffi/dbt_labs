FROM apache/airflow:3.1.5-python3.12

ARG AIRFLOW_VERSION=3.1.5
ARG PYTHON_VERSION=3.12

# 1) astronomer-cosmos (SANS l'extra [dbt-duckdb]) reste dans
#    l'environnement Airflow, contraint par le fichier officiel.
#    Cosmos lui-meme est leger (pas de conflit avec Airflow).
RUN pip install --no-cache-dir \
    --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt" \
    "astronomer-cosmos==1.15.*"

# 2) dbt-core + dbt-duckdb dans un venv COMPLETEMENT ISOLE de celui
#    d'Airflow. dbt a son propre arbre de dependances (protobuf,
#    click, jinja2...) qui entre en conflit avec celui d'Airflow des
#    qu'on essaie de les installer cote a cote dans le meme
#    environnement -- meme avec le fichier de contraintes officiel
#    (vecu en construisant cette image : `ResolutionImpossible`,
#    `protobuf==4.25.6` exige par Airflow vs. version differente
#    requise par la chaine de dependances de dbt-duckdb). C'est le
#    pattern officiellement recommande par Astronomer : ne JAMAIS
#    installer dbt-core dans l'environnement Python d'Airflow.
RUN python -m venv /home/airflow/dbt_venv && \
    /home/airflow/dbt_venv/bin/pip install --no-cache-dir "dbt-duckdb==1.10.*"
