# Projet dbt Labs - Apprentissage dbt

Ce projet est un template standard pour apprendre dbt (Data Build Tool). Il contient une structure complète avec des exemples de modèles, tests, et configurations.

## Structure du projet

```
dbt_labs/
├── analyses/          # Analyses ad-hoc (requêtes SQL non matérialisées)
├── data/              # Fichiers CSV pour les seeds
│   └── countries.csv
├── macros/            # Macros réutilisables
│   └── cents_to_dollars.sql
├── models/            # Modèles SQL
│   ├── staging/       # Modèles de staging (nettoyage initial)
│   │   ├── schema.yml
│   │   ├── stg_customers.sql
│   │   └── stg_orders.sql
│   └── marts/         # Modèles finaux (tables agrégées)
│       ├── schema.yml
│       └── customer_orders.sql
├── snapshots/         # Snapshots pour le suivi historique
├── tests/             # Tests personnalisés
│   └── assert_positive_value.sql
├── dbt_project.yml    # Configuration principale du projet
└── profiles.yml.example # Exemple de configuration de connexion
```

## Prérequis

1. Python 3.7 ou supérieur
2. dbt installé (via pip)

## Installation

### 1. Installer dbt

```bash
# Installer dbt avec le connecteur PostgreSQL
pip install dbt-postgres

# Ou pour d'autres bases de données :
# pip install dbt-bigquery
# pip install dbt-snowflake
# pip install dbt-redshift
# pip install dbt-duckdb
```

### 2. Configurer le profil de connexion

Copiez le fichier d'exemple et configurez-le avec vos informations de connexion :

```bash
# Créer le dossier de configuration dbt
mkdir -p ~/.dbt

# Copier et adapter le fichier de configuration
cp profiles.yml.example ~/.dbt/profiles.yml

# Éditer le fichier avec vos informations de connexion
nano ~/.dbt/profiles.yml
```

### 3. Vérifier la configuration

```bash
# Vérifier que dbt peut se connecter à votre base de données
dbt debug
```

## Commandes dbt essentielles

### Exécution des modèles

```bash
# Exécuter tous les modèles
dbt run

# Exécuter un modèle spécifique
dbt run --select stg_customers

# Exécuter tous les modèles dans un dossier
dbt run --select staging
dbt run --select marts

# Exécuter un modèle et ses dépendances
dbt run --select +customer_orders
```

### Tests

```bash
# Exécuter tous les tests
dbt test

# Tester un modèle spécifique
dbt test --select stg_customers

# Tester les sources
dbt test --select source:*
```

### Seeds

```bash
# Charger les fichiers CSV dans la base de données
dbt seed

# Charger un seed spécifique
dbt seed --select countries
```

### Documentation

```bash
# Générer la documentation
dbt docs generate

# Servir la documentation localement
dbt docs serve
```

### Autres commandes utiles

```bash
# Compiler les modèles sans les exécuter
dbt compile

# Nettoyer les fichiers générés
dbt clean

# Voir les dépendances d'un modèle
dbt ls --select +customer_orders
```

## Concepts clés de dbt

### 1. Sources (`source()`)
Les sources définissent les tables brutes dans votre base de données. Elles sont déclarées dans les fichiers `schema.yml`.

```sql
select * from {{ source('raw', 'customers') }}
```

### 2. Modèles (`ref()`)
Les modèles sont des transformations SQL. Utilisez `ref()` pour référencer d'autres modèles.

```sql
select * from {{ ref('stg_customers') }}
```

### 3. Matérialisations
- `view` : Crée une vue (par défaut)
- `table` : Crée une table
- `incremental` : Mise à jour incrémentale
- `ephemeral` : CTE réutilisable (pas de création en base)

### 4. Tests
- Tests génériques : `unique`, `not_null`, `accepted_values`, `relationships`
- Tests personnalisés : Requêtes SQL qui ne doivent retourner aucune ligne

### 5. Macros
Fonctions Jinja2 réutilisables pour générer du SQL dynamique.

## Workflow recommandé

1. Définir les sources dans `models/staging/schema.yml`
2. Créer des modèles de staging pour nettoyer les données brutes
3. Créer des modèles marts pour les analyses finales
4. Ajouter des tests pour valider la qualité des données
5. Documenter les modèles dans les fichiers `schema.yml`
6. Générer et consulter la documentation

## Exemple de développement

1. Modifier un modèle SQL
2. Compiler pour vérifier la syntaxe :
   ```bash
   dbt compile --select mon_modele
   ```
3. Exécuter le modèle :
   ```bash
   dbt run --select mon_modele
   ```
4. Tester le modèle :
   ```bash
   dbt test --select mon_modele
   ```

## Ressources

- [Documentation officielle dbt](https://docs.getdbt.com/)
- [dbt Learn](https://learn.getdbt.com/)
- [dbt Slack Community](https://www.getdbt.com/community/)
- [dbt Discourse](https://discourse.getdbt.com/)

## Prochaines étapes

1. Configurer votre connexion à la base de données dans `~/.dbt/profiles.yml`
2. Créer des tables sources dans votre base de données (customers, orders)
3. Exécuter `dbt seed` pour charger les données de référence
4. Exécuter `dbt run` pour créer vos modèles
5. Exécuter `dbt test` pour valider vos données
6. Exécuter `dbt docs generate && dbt docs serve` pour voir la documentation

Bon apprentissage avec dbt !
