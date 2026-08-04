# Module 04 — Incremental a l'echelle : la strategie `microbatch`

## Objectifs

- Comprendre pourquoi `microbatch` existe en plus de `delete+insert`/`append` (bootcamp 1).
- Configurer `event_time`, `batch_size`, `begin` correctement.
- Maitriser les backfills scopes (`--event-time-start`/`--event-time-end`).
- Connaitre le piege n°1 de microbatch (verifie en conditions reelles).

## Pourquoi pas juste `delete+insert` comme au bootcamp 1 ?

Le pattern du bootcamp 1 (`where updated_at > max(updated_at) deja
charge`) fonctionne tres bien... jusqu'a ce que vous ayez besoin de
**retraiter un mois specifique au milieu de l'historique** (un bug de
donnees decouvert 6 mois plus tard sur mars 2019, par exemple). Avec
un high-water mark simple, retraiter UNE periode passee sans tout
recalculer demande une gymnastique manuelle (filtrer temporairement,
desactiver `is_incremental()`...). `microbatch` (dbt >= 1.9) resout
exactement ce probleme : chaque periode (jour/semaine/mois) est un
lot independant, rejouable individuellement, en parallele, avec
retry par lot.

## Configuration, dans [`fct_trips.sql`](../nyc_taxi_dbt/models/marts/fct_trips.sql)

```sql
{{
    config(
        materialized='incremental',
        incremental_strategy='microbatch',
        event_time='pickup_at',
        batch_size='month',
        begin='2019-01-01',
    )
}}

select ... from {{ ref('stg_trips') }}
```

Pas de `{% if is_incremental() %}` a ecrire vous-meme : dbt injecte
AUTOMATIQUEMENT le filtre temporel de chaque lot. C'est pour ca que
`stg_trips` doit declarer `event_time='pickup_at'` (module 01) — sans
ca, dbt ne sait pas comment filtrer la source en amont pour chaque
lot, et vous recevez cet avertissement (rencontre en conditions
reelles pendant la construction de ce projet) :

```
WARNING: The microbatch model 'fct_trips' has no 'ref' or 'source'
input with an 'event_time' configuration. This means no filtering can
be applied and can result in unexpected duplicate records.
```

## Piege n°1, verifie en conditions reelles : microbatch se cale sur "maintenant", pas sur vos donnees

Premier `dbt run --select fct_trips` (sans bornes explicites) sur ce
projet : dbt a traite **91 lots mensuels**, de 2019-01 jusqu'a...
2026-07 — la date systeme du jour de l'execution. 88 de ces lots
etaient vides (aucune donnee au-dela de mars 2019 dans ce dataset),
mais chacun a quand meme ete ouvert/ferme comme une transaction a part
entiere : 88 secondes pour un run qui aurait du en prendre moins de 5.

Deuxieme surprise, apres avoir ajoute un 4e mois de donnees (avril
2019) et relance `dbt run` (toujours sans bornes explicites) : dbt a
traite les lots **"2026-06" et "2026-07"** — PAS "2019-04" — et n'a
donc rien insere du tout, alors que de nouvelles donnees existaient
bel et bien en amont.

**La regle a comprendre** : sans `--event-time-start`/`--event-time-end`
explicites, un `dbt run` normal sur un modele microbatch calcule sa
fenetre de lots par rapport a **l'heure reelle du systeme au moment du
run** (moins un "lookback" de securite), PAS par rapport au maximum
deja charge dans la table cible (contrairement au high-water mark
manuel du bootcamp 1). C'est un choix de conception assume : dbt part
du principe qu'un pipeline microbatch tourne sur un vrai calendrier
(un run par jour/mois, en phase avec le temps reel), pas sur un jeu de
donnees historique fige comme celui de ce bootcamp.

## Le correctif : des backfills EXPLICITEMENT scopes

```bash
# Chargement initial : janvier a mars (la borne de fin est EXCLUSIVE)
dbt run --select fct_trips --event-time-start 2019-01-01 --event-time-end 2019-04-01

# Nouvelles donnees arrivees (avril) : on scope exactement ce lot
dbt run --select fct_trips --event-time-start 2019-04-01 --event-time-end 2019-05-01
```

**`--event-time-end` est exclusive.** La premiere commande charge
janvier, fevrier, mars — pas avril. Pour tout charger d'un coup, la
borne est `2019-05-01`. Une erreur ici ne produit **aucun message** :
le run est vert, il manque simplement un mois. Voir
[module 01](../01-duckdb-a-lechelle/README.md) pour la demonstration
chiffree (24 M au lieu de 32 M).

Resultat mesure : 3 lots (jan/fev/mar) en ~2.6s pour le premier appel,
1 lot (avril) en ~1s pour le second — exactement ce qu'on attend,
sans aucun lot superflu. **En production**, sur un pipeline qui tourne
reellement au fil du temps (via Airflow, module 05/06), vous n'avez
PAS besoin de ces flags au quotidien : le calendrier reel et les
donnees qui arrivent chaque jour coincident naturellement. Ces flags
servent pour deux cas precis : le chargement initial d'un historique
(comme ici), et un backfill correctif cible sur une periode passee.

## `batch_size` : day / week / month / year

Choisissez en fonction du VOLUME par periode ET du besoin de
granularite de retraitement. `month` convient ici (~8M lignes/lot,
quelques secondes chacun sur DuckDB). Sur un flux a plus haute
frequence (evenements applicatifs, des centaines de millions de
lignes/jour), `day` est plus courant — quitte a avoir beaucoup plus de
lots, chacun reste petit et rapide a rejouer individuellement en cas
de probleme.

## Exercice

Un bug est decouvert : les donnees de fevrier 2019 ont ete chargees
avec un mauvais taux de `congestion_surcharge` (corrige depuis dans la
source). Ecrivez la commande qui retraite UNIQUEMENT ce mois, sans
toucher a janvier, mars ou avril.

### Solution

```bash
dbt run --select fct_trips --event-time-start 2019-02-01 --event-time-end 2019-03-01
```

Ne me croyez pas sur parole : **mesurez une empreinte avant/apres.**
Un simple `count(*)` ne suffit pas (il serait identique meme si un
mois avait ete recalcule) — ajoutez une somme :

```sql
select date_trunc('month', pickup_at) as mois,
       count(*), round(sum(fare_amount), 2)
from main.fct_trips group by 1 order by 1;
```

```
  2019-01-01   7 999 999  somme=139750783.41
  2019-02-01   8 000 000  somme=139724726.24
  2019-03-01   8 000 001  somme=139722184.35
  2019-04-01   7 999 998  somme=139729746.82
```

Lancez le backfill de fevrier :

```
Batch 1 of 1 START batch 2019-02 of main.fct_trips ... [RUN]
Batch 1 of 1 OK created batch 2019-02 of main.fct_trips [OK in 1.29s]
Done. PASS=1 ...
```

**`Batch 1 of 1`** — un seul lot ouvert, pas quatre. Et l'empreinte
apres coup : les quatre mois strictement identiques, total inchange a
31 999 998.

Grace a `microbatch`, dbt sait que ce lot existe deja dans la table
(logique interne : `DELETE` du lot + `INSERT` du lot recalcule, une
transaction par lot) — janvier, mars et avril ne sont ni relus ni
recalcules. C'est precisement l'avantage sur le pattern
`delete+insert` a la main du bootcamp 1 : la aussi le mecanisme est un
delete+insert, mais **scope automatiquement par periode**, sans avoir
a ecrire de logique `WHERE` manuelle a chaque nouveau cas de
retraitement partiel.

## Suite

→ [Module 05 — Orchestration Airflow](../05-orchestration-airflow/README.md)
