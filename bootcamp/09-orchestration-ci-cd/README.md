# Module 09 — Orchestration et CI/CD

## Objectifs

- Distinguer dbt Core (CLI, ce que vous utilisez dans ce bootcamp) de
  dbt Cloud (plateforme managee : scheduler, IDE, Semantic Layer
  hebergee).
- Construire une CI dbt complete avec GitHub Actions.
- Comprendre et implementer le "slim CI" (`state:modified+`).
- Situer dbt dans un orchestrateur externe (Airflow/Dagster).

## dbt Core vs dbt Cloud : ce que dbt Cloud ajoute

dbt Core = le CLI que vous utilisez depuis le module 00. dbt Cloud
ajoute par-dessus : un scheduler managé (pas besoin de GitHub
Actions/Airflow pour declencher les runs), un IDE web, l'hebergement
du Semantic Layer (module 08) sans installer `dbt-metricflow`
vous-meme, et une gestion d'environnements/CI integree ("slim CI"
sans configurer d'artifacts vous-meme). Tout ce que vous avez
construit dans ce bootcamp fonctionne a l'identique sur les deux — ce
module montre la version "je construis tout moi-meme", pour bien
comprendre ce que dbt Cloud automatise ensuite.

## La CI complete de ce projet

[`.github/workflows/dbt_ci.yml`](../../.github/workflows/dbt_ci.yml),
job `dbt_build_and_test`, execute a chaque push sur `main` et chaque
PR :

1. Demarre un service Postgres (conteneur ephemere du runner GitHub).
2. Charge le schema `raw` avec le MEME script SQL que votre Postgres
   local (`postgres/init-scripts/01_raw_schema.sql`) — la CI
   reproduit fidelement l'environnement de dev, pas un mock.
3. Ecrit un `profiles.yml` de CI a la volee (target `ci`, schema
   `ci_<run_id>` — **chaque run est isole dans son propre schema**,
   zero collision entre deux PR qui tournent en parallele).
4. `dbt deps && dbt seed && dbt build && dbt snapshot`.
5. Si c'est un push sur `main` : publie `target/manifest.json` en
   artifact GitHub — c'est cet artifact que le "slim CI" va
   consommer.

## Slim CI : ne reconstruire que ce qui a change

Sur un projet de 20 modeles (celui-ci), un `dbt build` complet prend
2 secondes. Sur un projet de 800 modeles en production, ca peut
prendre 40 minutes — inacceptable pour chaque push d'une PR qui ne
touche qu'un seul modele.

Le principe : dbt compare l'etat ACTUEL du projet (le code de la PR)
a un **manifest de reference** (celui du dernier build reussi sur
`main`), et ne selectionne que ce qui a un SQL/YAML different
(`state:modified`), plus tout ce qui en depend en aval (`+`) :

```bash
dbt build --select "state:modified+" --state ./state
```

`./state` = le dossier contenant le `manifest.json` de reference
(telecharge depuis l'artifact `dbt-manifest-main` du dernier run
`main`, via l'action tierce `dawidd6/action-download-artifact` — les
artifacts GitHub natifs ne sont accessibles QUE dans le meme run,
d'ou le besoin d'un outil externe pour aller chercher celui d'un run
precedent sur une autre branche). Voir le job `slim_ci_on_pr` du
workflow.

Ce pattern est aussi encapsule dans un **selecteur nomme reutilisable**,
[`selectors.yml`](../../selectors.yml) :

```yaml
selectors:
  - name: ci_changed
    definition:
      method: state
      value: modified
      children: true
```

```bash
dbt build --selector ci_changed --state ./state
```

Un selecteur nomme evite de retaper/desynchroniser la meme chaine
`--select` complexe dans plusieurs endroits (CI, scripts locaux,
documentation).

### Essayez-le maintenant, en local, en 30 secondes

Pas besoin d'attendre une PR : `--state` accepte n'importe quel
dossier contenant un `manifest.json`.

```bash
mkdir -p /tmp/state_ref && cp target/manifest.json /tmp/state_ref/
dbt ls --select "state:modified+" --state /tmp/state_ref
```

```
The selection criterion 'state:modified+' does not match any enabled nodes
No nodes selected!
```

Logique : vous comparez le projet a lui-meme. Maintenant, touchez un
modele :

```bash
echo "-- commentaire de test" >> models/staging/stg_products.sql
dbt ls --select "state:modified+" --state /tmp/state_ref --resource-type model
```

```
dbt_labs.marts.core.dim_products
dbt_labs.marts.returns.product_return_rates
dbt_labs.staging.stg_products
```

**3 modeles sur 15.** Le modifie, plus ses deux consommateurs en aval
— y compris `product_return_rates`, qui appartient a un autre
domaine. C'est exactement ce qu'une CI doit reconstruire, et rien de
plus.

**Le detail qui surprend** : un simple **commentaire** a suffi.
`state:modified` compare le SQL brut du fichier, pas son sens. Un
reformatage, un commentaire ajoute, un espace en fin de ligne
declenchent une reconstruction complete de l'aval.

Ce n'est pas un defaut — dbt ne peut pas prouver qu'un changement
textuel est semantiquement neutre, et se tromper dans ce sens serait
bien pire (ne pas reconstruire ce qui aurait du l'etre). Mais ca a
une consequence concrete : **evitez de reformater 200 fichiers dans
la meme PR que vos changements fonctionnels**, sinon votre slim CI
reconstruit tout et vous perdez le benefice. Separez les PR de
formatage des PR de logique.

## Hooks : executer du SQL avant/apres un run

`dbt_project.yml` supporte `on-run-start`/`on-run-end` (niveau
projet) et `pre-hook`/`post-hook` (niveau modele). Exemple courant en
observabilite (approfondi au module 11) :

```yaml
on-run-end:
  - "{{ log('dbt run termine : ' ~ results|length ~ ' noeuds executes', info=True) }}"
```

Les index Postgres de `fct_orders` (module 05,
`config(indexes=[...])`) sont en realite un sucre syntaxique dbt
au-dessus d'un `post-hook` — dbt genere et execute le `CREATE INDEX`
automatiquement apres la (re)creation de la table.

## Orchestrer dbt depuis l'exterieur (Airflow / Dagster)

GitHub Actions declenche dbt sur evenement git (push/PR). Mais QUI
declenche `dbt run` en production, tous les jours a 6h, apres que les
donnees sources soient arrivees ? Reponse : un orchestrateur externe.

- **Airflow** : `BashOperator`/`KubernetesPodOperator` executant
  `dbt build`, ou le package `astronomer-cosmos` qui transforme
  automatiquement chaque modele dbt en tache Airflow individuelle
  (parallelisme et retry par modele, pas juste par commande globale).
- **Dagster** : `dagster-dbt` fait de meme, avec en plus une vraie
  representation du DAG dbt DANS le DAG Dagster (assets).

Dans les deux cas, dbt reste "juste" le T de l'ELT : l'orchestrateur
decide QUAND lancer, dbt decide QUOI faire et DANS QUEL ORDRE une
fois lance.

## Exercice

Avant de pousser une branche, vous voulez tester localement UNIQUEMENT
ce que la slim CI testerait sur GitHub — sans attendre le push. Ecrivez
un script `scripts/check_before_push.sh` qui : sauvegarde l'etat
actuel du manifest, applique vos changements, et lance
`dbt build --select state:modified+` contre ce manifest de reference.

### Solution

```bash
#!/usr/bin/env bash
# scripts/check_before_push.sh
set -euo pipefail

set -a && source .env && set +a

echo "1. Snapshot du manifest de reference (etat de 'main')..."
git stash push --include-untracked -m "check_before_push wip"
dbt parse --target dev   # genere target/manifest.json pour l'etat de main
mkdir -p /tmp/dbt_state_main
cp target/manifest.json /tmp/dbt_state_main/manifest.json
git stash pop

echo "2. Build slim contre ce manifest de reference..."
dbt build --select "state:modified+" --state /tmp/dbt_state_main
```

Mecanisme : `git stash` met de cote vos changements en cours pour
generer un manifest qui reflete `main` (ou votre dernier commit
propre) ; on le sauvegarde HORS du dossier `target/` habituel (sinon
l'etape suivante l'ecraserait) ; `git stash pop` restaure vos
changements ; puis `dbt build --state` compare votre code actuel a
CE manifest de reference. C'est exactement ce que fait la CI, en
local, avant meme d'ouvrir la PR — un filet de securite rapide qui
evite des allers-retours CI pour des erreurs qu'on aurait pu voir
soi-meme en 5 secondes.

## Suite

→ [Module 10 — Gouvernance et architecture multi-projets](../10-gouvernance-multi-projets/README.md)
