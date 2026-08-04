# Module 02 — Connecter de vraies donnees distantes (httpfs)

## Objectifs

- Interroger des fichiers parquet distants SANS les telecharger.
- Comprendre `union_by_name` face au schema drift sur plusieurs annees.
- Savoir diagnostiquer un blocage reseau (WAF/CDN) en conditions reelles.
- Basculer ce projet des donnees locales vers les vraies donnees publiques NYC TLC.

## Le vrai jeu de donnees public

Les fichiers utilises pour generer ce bootcamp existent reellement,
en acces libre, sans authentification :
`https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_YYYY-MM.parquet`
(publies par la NYC Taxi & Limousine Commission, un fichier par mois,
2009 a aujourd'hui).

## `read_parquet` a distance : la meme fonction, une URL en plus

```sql
select count(*)
from read_parquet('https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2019-01.parquet')
```

**Mesure reelle, capturee en construisant ce bootcamp** : cette
requete renvoie `7 696 617` en **moins de 3 secondes** — sans
telecharger le fichier (110 Mo) en entier. DuckDB lit d'abord le
FOOTER du fichier parquet (metadonnees + stats par row group), et pour
un simple `count(*)`, n'a besoin de rien d'autre.

## Passer a l'echelle : une LISTE d'URLs, pas un glob

Contrairement a un chemin local (`data/**/*.parquet`), HTTP(S) ne sait
pas "lister un dossier" — DuckDB ne peut donc pas faire de glob sur
une URL. La solution : construire la liste explicite des fichiers a
lire (une URL par mois), et la passer telle quelle a `read_parquet`,
qui accepte une liste :

```python
urls = [
    f"https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_{y}-{m:02d}.parquet"
    for y in range(2016, 2022)
    for m in range(1, 13)
]
# select count(*) from read_parquet(urls, union_by_name=true)
```

**Mesure reelle** : 72 fichiers (2016-2021), **487 655 363 lignes,
comptees en moins de 10 secondes**, sans rien stocker localement.
Largement au-dessus des "200 millions de lignes" vises par ce
bootcamp — et ce n'est qu'un COUNT ; des agregations plus lourdes
prendraient plus longtemps, mais restent de l'ordre de la dizaine de
secondes a quelques minutes sur ce volume avec DuckDB.

## `union_by_name=true` : le schema derive sur plusieurs annees

Le schema des fichiers NYC TLC a legerement change au fil des ans
(ajout de `congestion_surcharge` en 2019, d'`airport_fee` plus tard...).
Sans `union_by_name=true`, `read_parquet` sur une liste de fichiers
suppose que la colonne N d'un fichier correspond a la colonne N de
tous les autres — un fichier 2016 (sans `congestion_surcharge`) et un
fichier 2021 (avec) produiraient un decalage silencieux de colonnes
au lieu d'une erreur. `union_by_name=true` aligne par NOM de colonne,
et remplit de `NULL` les colonnes absentes d'un fichier donne :
exactement le comportement voulu, et ce qui a permis a la requete
2016-2021 ci-dessus de reussir sans configuration supplementaire.

## Basculer CE projet sur les vraies donnees

Un seul changement, dans [`dbt_project.yml`](../nyc_taxi_dbt/dbt_project.yml) :

```yaml
vars:
  raw_trips_glob: >
    ['https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2019-01.parquet',
     'https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2019-02.parquet',
     'https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_2019-03.parquet']
```

Rien d'autre ne change — ni `stg_trips.sql`, ni `fct_trips.sql`, ni
les tests. C'est exactement l'interet d'avoir isole le glob dans une
`var()` des le module 01 : la source physique des donnees est un
detail de configuration, pas une decision structurante du DAG.

## Piege reel : un CDN peut vous bloquer, et ce n'est pas de votre faute

En construisant ce bootcamp, une rafale de 3 telechargements complets
en parallele (`curl` sur des fichiers de 110 Mo chacun) a declenche un
blocage WAF CloudFront — **toutes** les requetes suivantes vers ce
meme nom de domaine, y compris de simples requetes `HEAD` qui
fonctionnaient l'instant d'avant, ont commence a renvoyer :

```
HTTP/2 403
Request blocked.
We can't connect to the server for this app or website at this time.
```

Methode de diagnostic qui a permis de confirmer que c'etait bien
specifique a ce CDN (et pas une panne reseau generale) :

```bash
curl -s -o /dev/null -w "%{http_code}\n" https://www.google.com                          # 200 -> internet OK
curl -s -o /dev/null -w "%{http_code}\n" https://raw.githubusercontent.com/...            # 200 -> HTTPS OK
curl -s -o /dev/null -w "%{http_code}\n" https://d37ci6vzurychx.cloudfront.net/...        # 403 -> CE domaine seulement
```

**La lecon a retenir** : quand vous interrogez un CDN public partage
(pas une API que vous controlez), ne PARALLELISEZ JAMAIS des
telechargements complets sans limite de debit/concurrence — meme un
usage legitime peut ressembler a une attaque du point de vue d'un WAF.
Pour de la lecture DuckDB a distance en production sur ce genre de
source, preferez : (1) des requetes sequentielles ou a concurrence
limitee, (2) mettre en cache localement les fichiers deja lus (le
pattern local du module 01), (3) si disponible, un mirroir S3/GCS
avec des credentials dedies plutot qu'un CDN public anonyme.

## Exercice

Sans rien telecharger, ecrivez la requete DuckDB qui calcule le
revenu total (`total_amount`) par annee sur 2018-2020, directement
depuis les URLs distantes.

### Solution

```python
import duckdb

con = duckdb.connect()
con.execute("install httpfs; load httpfs;")

urls = [
    f"https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_{y}-{m:02d}.parquet"
    for y in range(2018, 2021)
    for m in range(1, 13)
]

result = con.execute(f"""
    select
        year(tpep_pickup_datetime) as trip_year,
        round(sum(total_amount), 0) as total_revenue,
        count(*) as trip_count
    from read_parquet({urls}, union_by_name=true)
    group by 1
    order by 1
""").fetchall()
print(result)
```

Cette requete est plus couteuse qu'un simple `count(*)` (elle doit
reellement lire la colonne `total_amount` de chaque ligne, pas
seulement les metadonnees) — attendez-vous a plusieurs dizaines de
secondes selon votre connexion, contre quelques secondes pour un
`count(*)` pur. C'est une distinction utile a avoir en tete : DuckDB
optimise agressivement ce qu'il PEUT eviter de lire, mais ne fait pas
de miracle des que la requete a reellement besoin du contenu de
chaque ligne.

## Suite

→ [Module 03 — Partitioning, clustering, performance](../03-partitioning-perf/README.md)
