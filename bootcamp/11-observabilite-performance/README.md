# Module 11 — Observabilite et performance avancee

## Objectifs

- Exploiter `store_failures` pour auditer des tests en echec.
- Lire les artifacts dbt (`manifest.json`, `run_results.json`, `catalog.json`).
- Lire un plan d'execution Postgres (`EXPLAIN ANALYZE`) sur du SQL genere par dbt.
- Savoir ou l'ecosysteme (Elementary, dbt docs) s'insere.

## `store_failures` : ne pas juste savoir QU'un test echoue, mais QUOI

Un test qui echoue vous dit "1 ligne en anomalie" — pas LAQUELLE, une
fois le run termine et les logs perdus dans le flot de CI. Avec
`store_failures`, dbt materialise les lignes en echec dans une vraie
table, interrogeable APRES coup :

```sql
-- tests/assert_payments_reconcile_with_orders.sql
{{ config(severity='warn', store_failures=true, schema='dbt_test_failures') }}
```

**Demonstration reelle**, faite pour ecrire ce module : on a
volontairement corrompu un paiement (`amount_cents + 500` sur la
commande 5), relance `dbt run --full-refresh` puis `dbt test` :

```
Warning in test assert_payments_reconcile_with_orders
Got 1 result, configured to warn if != 0

  See test failures:
  --------------------------------------------------------------
  select * from "dbt_labs"."dbt_jeff_dbt_test_failures"."assert_payments_reconcile_with_orders"
  --------------------------------------------------------------
```

```sql
select * from "dbt_jeff_dbt_test_failures".assert_payments_reconcile_with_orders;
```

```
 order_id | subtotal_cents | total_paid_cents | delta_cents
----------+----------------+------------------+-------------
        5 |          24794 |            25294 |         500
```

La ligne exacte, avec le montant exact de l'ecart — exploitable
directement par un analyste ou un outil de monitoring qui interroge
cette table periodiquement, sans avoir a re-executer le test. (La
donnee corrompue a ete revertie immediatement apres cette
demonstration — ne laissez jamais un tel etat dans un environnement
partage.)

**Ou l'utiliser** : sur les tests `severity='warn'` a fort volume
potentiel de faux positifs (comme ici) — pour un test `error` sur une
cle primaire, l'echec bloque de toute facon le build, moins besoin
d'audit differe.

### La table existe meme quand le test passe

Interrogez-la maintenant, sur des donnees saines :

```sql
select * from "dbt_jeff_dbt_test_failures".assert_payments_reconcile_with_orders;
```

```
 order_id | subtotal_cents | total_paid_cents | delta_cents
----------+----------------+------------------+-------------
(0 rows)
```

**La table existe, elle est vide.** dbt la recree (`CREATE TABLE AS`)
a chaque execution du test, avec le resultat du moment — zero ligne
quand tout va bien.

Deux consequences pour qui construit du monitoring par-dessus :

- **"Table absente" et "table vide" ne veulent pas dire la meme
  chose.** Vide = le test a tourne et n'a rien trouve. Absente = le
  test n'a jamais tourne. Un tableau de bord qui confond les deux
  affichera "tout va bien" alors que plus rien ne s'execute.
- **Le contenu est ecrase, pas accumule.** Vous voyez l'echec du
  DERNIER run, jamais l'historique. Pour suivre une derive dans le
  temps, il faut copier ces lignes ailleurs apres chaque run (avec un
  horodatage) — c'est une partie de ce qu'automatise Elementary.

## Les artifacts dbt : la source de verite machine-readable

Chaque commande dbt ecrit dans `target/` :

| Fichier | Contenu | Usage |
|---|---|---|
| `manifest.json` | Le graphe complet du projet compile (tous les noeuds, leur SQL compile, leurs configs, leur lineage) | Slim CI (module 09), outils tiers (Elementary, dbt-checkpoint) |
| `run_results.json` | Le resultat du DERNIER run/test (succes/echec, duree par noeud) | Dashboards de monitoring de pipeline, alerting |
| `catalog.json` | Les metadonnees REELLES de l'entrepot (colonnes, types effectifs) apres `dbt docs generate` | `dbt docs serve`, detection de drift schema |

Exemple concret : combien de temps a pris chaque modele au dernier
run ?

```bash
python3 -c "
import json
data = json.load(open('target/run_results.json'))
for r in sorted(data['results'], key=lambda x: -x['execution_time'])[:5]:
    print(f\"{r['execution_time']:.3f}s  {r['unique_id']}\")
"
```

**Piege a connaitre avant de croire ce que ce script affiche** :
`run_results.json` est **ecrase a chaque commande**, et ne contient
que les noeuds de la DERNIERE commande. Si vous venez de lancer
`dbt snapshot`, vous obtenez :

```
0.157s  snapshot.dbt_labs.scd_customers
```

...une seule ligne, et surement pas le classement des modeles les
plus lents. Pour un profil complet, relancez `dbt build` juste avant
de lire le fichier. En CI, c'est la meme contrainte : archivez
`run_results.json` **immediatement** apres la commande qui vous
interesse, sinon l'etape suivante l'ecrase.

Meme logique pour `manifest.json` (ecrase par toute commande, y
compris `dbt parse`) — c'est precisement pourquoi le slim CI du
module 09 copie le manifest de reference **hors** de `target/` avant
de continuer.

C'est exactement le genre de script qu'un outil comme **Elementary**
(package dbt + plateforme d'observabilite open-source) automatise :
il ingere `run_results.json`/`manifest.json` a chaque run et vous
donne un dashboard d'anomalies de freshness, de volumes, de duree
d'execution — sans que vous ayez a ecrire ces scripts vous-meme. Pas
installe dans ce bootcamp (poids/scope), mais c'est l'etape naturelle
suivante des que ce projet grandit au-dela d'une poignee de modeles.

## Lire un plan d'execution Postgres

dbt genere le SQL ; comprendre s'il est performant reste votre job.
Exemple reel, execute sur ce projet :

```sql
explain analyze
select c.customer_id, count(o.order_id)
from "dbt_jeff_marts".fct_orders o
right join "dbt_jeff_marts".dim_customers c on c.customer_id = o.customer_id
group by c.customer_id;
```

```
HashAggregate  (cost=18.90..20.90 rows=200 width=12) (actual time=0.096..0.102 rows=25 loops=1)
  Group Key: c.customer_id
  ->  Hash Left Join  (cost=4.03..17.85 rows=210 width=8) (actual time=0.069..0.080 rows=90 loops=1)
        Hash Cond: (c.customer_id = o.customer_id)
        ->  Seq Scan on dim_customers c  (cost=0.00..12.10 rows=210 width=4) (actual time=0.019..0.020 rows=25 loops=1)
        ->  Hash  (cost=2.90..2.90 rows=90 width=8) (actual time=0.037..0.037 rows=90 loops=1)
              ->  Seq Scan on fct_orders o  (cost=0.00..2.90 rows=90 width=8) (actual time=0.005..0.013 rows=90 loops=1)
Planning Time: 0.334 ms
Execution Time: 0.163 ms
```

A lire de l'interieur vers l'exterieur (les operations les plus
imbriquees s'executent en premier) :

- Le planner a **reecrit mon `RIGHT JOIN` en `Hash Left Join`**
  (avec les tables inversees) — Postgres choisit toujours le plan
  qu'il juge le moins couteux, votre syntaxe SQL n'est qu'une
  DEMANDE, pas un ordre d'execution litteral.
- `Seq Scan` (balayage complet de la table) sur les deux tables — normal
  et optimal ici : 25 et 90 lignes, un index couterait plus cher a
  maintenir qu'il ne ferait gagner de temps de lecture.
- `actual time` (temps REEL mesure) vs `cost` (estimation du
  planner, unite arbitraire) : sur un petit volume les deux
  convergent ; sur de gros volumes, un `cost` tres eloigne du
  comportement observe signale des statistiques perimees
  (`ANALYZE nom_table` a lancer).

**Sur des volumes de production**, le meme plan sur des tables de
plusieurs millions de lignes montrerait un `Seq Scan` remplace par un
`Index Scan` (si un index existe et est selectif), ou un `Hash Join`
remplace par un `Merge Join` si les deux cotes sont deja tries.
C'est precisement pour orienter ce choix que le module 05 configure
des `indexes` sur `fct_orders` (`order_id`, `customer_id`) : sans eux,
tout `WHERE order_id = ...` ou `JOIN ... ON customer_id` degraderait
en `Seq Scan` des que la table depasse quelques dizaines de milliers
de lignes.

## `dbt docs` comme outil d'observabilite, pas juste de documentation

```bash
dbt docs generate   # combine manifest.json + catalog.json (introspection reelle de l'entrepot)
dbt docs serve
```

Au-dela du DAG visuel, `dbt docs generate` DETECTE le drift entre ce
que le YAML documente et ce qui existe REELLEMENT dans l'entrepot
(colonnes catalguees absentes du YAML, types differents) — un premier
niveau gratuit de detection d'anomalie de schema, avant meme un
contrat formel (module 07).

## Exercice

Le test `store_failures` cree une table par test en echec, qui
s'accumule sans jamais etre nettoyee automatiquement. Ecrivez la
commande qui liste tous les schemas de test-failures generes par ce
projet, et expliquez pourquoi `dbt clean` NE les supprime PAS.

### Solution

```sql
select schema_name
from information_schema.schemata
where schema_name like '%dbt_test_failures%';
```

`dbt clean` supprime uniquement les dossiers locaux configures dans
`clean-targets` de `dbt_project.yml` (`target/`, `dbt_packages/` ici)
— des fichiers sur votre disque. Les tables `store_failures` sont des
objets crees DANS l'entrepot, sur un warehouse potentiellement
partage par toute une equipe : dbt ne les supprime jamais
automatiquement, pour la meme raison qu'il ne supprime jamais une
table de production sans qu'on le lui demande explicitement
(`dbt run --select model --full-refresh` recree une table, mais ne
supprime pas des tables devenues orphelines — voir la commande
`dbt run-operation` ou un job de nettoyage dedie en CI si ce
comportement pose probleme a l'echelle).

## Suite

→ [Module 12 — Projet capstone](../12-projet-capstone/README.md)
