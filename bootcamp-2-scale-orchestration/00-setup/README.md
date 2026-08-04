# Module 00 — Setup

## Objectifs

- Installer `dbt-duckdb` dans un venv dedie.
- Comprendre pourquoi DuckDB simplifie radicalement l'etape "setup"
  par rapport a Postgres (bootcamp 1).
- Generer le jeu de donnees synthetique du bootcamp.

## DuckDB : pas de serveur, pas de Docker, pas de secrets

Comparez les deux profils dbt de ce repo :

```yaml
# bootcamp 1 (Postgres) -- ~/.dbt/profiles.yml
dbt_labs:
  outputs:
    dev:
      type: postgres
      host: "{{ env_var('POSTGRES_HOST') }}"
      port: "{{ env_var('POSTGRES_PORT') | as_number }}"
      user: "{{ env_var('POSTGRES_USER') }}"
      password: "{{ env_var('POSTGRES_PASSWORD') }}"
      dbname: "{{ env_var('POSTGRES_DB') }}"

# bootcamp 2 (DuckDB) -- nyc_taxi_dbt/profiles.yml
nyc_taxi_dbt:
  outputs:
    dev:
      type: duckdb
      path: 'nyc_taxi.duckdb'
```

DuckDB est une base **embarquee** : le "serveur" est une librairie liee
dans le process dbt lui-meme, et l'entrepot entier est UN fichier sur
disque. Consequence directe : zero Docker Compose, zero identifiants,
zero risque de fuite de secret (il n'y en a pas). C'est pour ca que
`profiles.yml` de ce projet peut etre commite dans git sans risque
(voir [`nyc_taxi_dbt/profiles.yml`](../nyc_taxi_dbt/profiles.yml)) —
totalement impossible a faire sereinement pour le profil Postgres du
premier bootcamp.

**Ce que vous perdez en echange** (a bien comprendre, ce n'est pas
gratuit) : pas de concurrence multi-utilisateurs en ecriture (un seul
process peut ecrire dans le fichier `.duckdb` a la fois — pertinent
pour le module 05/06 : Airflow et vous ne pouvez pas lancer `dbt run`
en meme temps sur le meme fichier), pas de serveur toujours allume
consultable par d'autres outils BI simultanement. DuckDB brille pour
de l'analytique locale/batch a gros volume ; Postgres (ou un
entrepot cloud) reste necessaire des qu'il faut du multi-acces
concurrent en production.

## Installation

```bash
cd bootcamp-2-scale-orchestration/nyc_taxi_dbt
python3 -m venv .venv
```

**Piege reel rencontre en installant ce projet** : sur macOS, avec le
Python de python.org, `pip install dbt-duckdb` peut echouer avec :

```
RuntimeError: failed to download https://github.com/.../dbt_core_experimental_parser-....whl:
<urlopen error [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed:
unable to get local issuer certificate>
```

Cause : le Python de python.org (macOS) ne pointe pas vers un magasin
de certificats CA valide tant que vous n'avez pas execute son script
`Install Certificates.command` — un souci classique et documente de
cette distribution Python specifiquement, sans rapport avec dbt.
Correctif (sans toucher a l'installation Python globale) :

```bash
pip install certifi
export SSL_CERT_FILE=$(python -c "import certifi; print(certifi.where())")
pip install "dbt-core<2.0" dbt-duckdb
```

Une fois installe :

```bash
export SSL_CERT_FILE=$(.venv/bin/python -c "import certifi; print(certifi.where())")
.venv/bin/dbt debug
```

`dbt debug` doit passer immediatement — pas de service a attendre, pas
de `docker compose up`.

## Generer le jeu de donnees

```bash
.venv/bin/python scripts/generate_synthetic_trips.py
```

Genere ~24 millions de lignes (3 mois, schema NYC TLC) en **moins de
15 secondes**, dans `data/raw_parquet/pickup_year=2019/pickup_month=NN/trips.parquet`
(partitionnement Hive — module 03) + un referentiel de zones dans
`seeds/taxi_zone_lookup.csv`.

## Exercice

Modifiez `scripts/generate_synthetic_trips.py` pour generer un
4eme mois (avril 2019) des le depart, et verifiez que le volume total
observe correspond bien a 4 x 8 000 000 lignes.

### Solution

```python
MONTHS = [(2019, 1, 31), (2019, 2, 28), (2019, 3, 31), (2019, 4, 30)]
```

```bash
.venv/bin/python scripts/generate_synthetic_trips.py
.venv/bin/python -c "
import duckdb
con = duckdb.connect()
print(con.execute(\"select count(*) from read_parquet('data/raw_parquet/**/*.parquet', hive_partitioning=true)\").fetchone())
"
# (32000000,)
```

Notez que cette verification se fait SANS `dbt` — juste DuckDB lisant
directement les fichiers parquet generes. C'est un reflexe utile :
valider les donnees brutes independamment du projet dbt avant de
lancer la moindre transformation, pour isoler "probleme de donnees"
de "probleme de modele".

## Suite

→ [Module 01 — DuckDB a l'echelle](../01-duckdb-a-lechelle/README.md)
