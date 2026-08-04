-- =====================================================================
-- dbt Bootcamp - jeu de données "raw" (système source simulé)
-- =====================================================================
-- Ce script est monté dans /docker-entrypoint-initdb.d/ et exécuté une
-- seule fois, au tout premier démarrage du conteneur Postgres (volume
-- vide). Il simule un système opérationnel (ex: base applicative d'un
-- site e-commerce) dont dbt va lire les données via des `source()`.
--
-- Toutes les dates sont calculées relativement à now() au moment de
-- l'initialisation du conteneur, pour que les données restent "fraîches"
-- quel que soit le jour où vous lancez `docker compose up` (utile pour
-- le module 07 - source freshness).
-- =====================================================================

create schema if not exists raw;

-- ---------------------------------------------------------------------
-- Rôle applicatif en lecture seule, utilisé au module 07 (gouvernance /
-- grants). On ne s'en sert pas pour se connecter, juste pour illustrer
-- des GRANT réels sur des objets créés par dbt.
-- ---------------------------------------------------------------------
do $$
begin
    if not exists (select from pg_roles where rolname = 'bi_reader') then
        create role bi_reader nologin;
    end if;
end
$$;

-- =====================================================================
-- raw.customers
-- =====================================================================
drop table if exists raw.customers cascade;
create table raw.customers (
    customer_id      integer primary key,
    first_name       text not null,
    last_name        text not null,
    email            text not null,
    country_code     text not null,
    customer_segment text not null default 'standard',
    created_at       timestamp not null,
    updated_at       timestamp not null,
    -- Horodatage technique d'extraction (distinct de updated_at, qui
    -- est un horodatage METIER). C'est LUI qu'on surveille en source
    -- freshness (module 07) : la date de creation d'un client peut
    -- avoir des mois, ca ne veut pas dire que le pipeline d'ingestion
    -- est en panne.
    _loaded_at       timestamp not null default now()
);

insert into raw.customers
    (customer_id, first_name, last_name, email, country_code, customer_segment, created_at, updated_at)
select
    c.customer_id,
    c.first_name,
    c.last_name,
    lower(c.first_name || '.' || c.last_name || '@example.com'),
    c.country_code,
    c.customer_segment,
    now() - ((220 - c.customer_id * 5) || ' days')::interval as created_at,
    now() - ((220 - c.customer_id * 5) || ' days')::interval as updated_at
from (values
    (1,  'Amelie',      'Girard',    'FR', 'vip'),
    (2,  'Lucas',       'Bernard',   'FR', 'standard'),
    (3,  'Chloe',       'Moreau',    'FR', 'standard'),
    (4,  'Hugo',        'Lefevre',   'FR', 'standard'),
    (5,  'Emma',        'Rousseau',  'FR', 'vip'),
    (6,  'James',       'Smith',     'US', 'standard'),
    (7,  'Olivia',      'Johnson',   'US', 'standard'),
    (8,  'Liam',        'Williams',  'US', 'vip'),
    (9,  'Sophia',      'Brown',     'US', 'standard'),
    (10, 'Noah',        'Davis',     'US', 'standard'),
    (11, 'Amelia',      'Wilson',    'UK', 'standard'),
    (12, 'Oliver',      'Taylor',    'UK', 'vip'),
    (13, 'Isla',        'Evans',     'UK', 'standard'),
    (14, 'George',      'Walker',    'UK', 'standard'),
    (15, 'Freya',       'Hughes',    'UK', 'standard'),
    (16, 'Maximilian',  'Schmidt',   'DE', 'standard'),
    (17, 'Mia',         'Fischer',   'DE', 'vip'),
    (18, 'Elias',       'Weber',     'DE', 'standard'),
    (19, 'Lina',        'Wagner',    'DE', 'standard'),
    (20, 'Paul',        'Becker',    'DE', 'standard'),
    (21, 'Lucia',       'Garcia',    'ES', 'standard'),
    (22, 'Martina',     'Lopez',     'ES', 'vip'),
    (23, 'Giulia',      'Russo',     'IT', 'standard'),
    (24, 'Marco',       'Ferrari',   'IT', 'standard'),
    (25, 'Olivia',      'Tremblay',  'CA', 'standard')
) as c(customer_id, first_name, last_name, country_code, customer_segment);

-- =====================================================================
-- raw.products
-- =====================================================================
drop table if exists raw.products cascade;
create table raw.products (
    product_id       integer primary key,
    product_name     text not null,
    category         text not null,
    unit_price_cents integer not null,
    is_active        boolean not null default true,
    created_at       timestamp not null,
    _loaded_at       timestamp not null default now()
);

insert into raw.products
    (product_id, product_name, category, unit_price_cents, is_active, created_at)
select
    p.product_id,
    p.product_name,
    p.category,
    p.unit_price_cents,
    p.is_active,
    now() - ((330 - p.product_id * 3) || ' days')::interval
from (values
    (1,  'Wireless Mouse',              'Electronics',    2499,  true),
    (2,  'Mechanical Keyboard',         'Electronics',    8999,  true),
    (3,  'USB-C Hub',                   'Electronics',    3499,  true),
    (4,  'Noise Cancelling Headphones', 'Electronics',   19999,  true),
    (5,  'Laptop Stand',                'Electronics',    4599,  true),
    (6,  'The Pragmatic Programmer',    'Books',          3299,  true),
    (7,  'Clean Code',                  'Books',          3499,  true),
    (8,  'Atomic Habits',               'Books',          1899,  true),
    (9,  'Cast Iron Skillet',           'Home & Kitchen', 5499,  true),
    (10, 'French Press',                'Home & Kitchen', 2999,  true),
    (11, 'Blender',                     'Home & Kitchen', 6999,  true),
    (12, 'Yoga Mat',                    'Sports',         2499,  true),
    (13, 'Adjustable Dumbbells',        'Sports',         8999,  true),
    (14, 'Building Blocks Set',         'Toys',           3999,  true),
    (15, 'Puzzle 1000 pieces',          'Toys',           1599,  false)
) as p(product_id, product_name, category, unit_price_cents, is_active);

-- =====================================================================
-- raw.orders  (90 commandes sur les 90 derniers jours)
-- =====================================================================
drop table if exists raw.orders cascade;
create table raw.orders (
    order_id     integer primary key,
    customer_id  integer not null references raw.customers(customer_id),
    order_status text not null,
    ordered_at   timestamp not null,
    updated_at   timestamp not null,
    -- Horodatage technique d'extraction, comme sur raw.customers.
    -- C'est LUI que surveille la source freshness (module 07), jamais
    -- updated_at (metier) ni ordered_at (metier).
    _loaded_at   timestamp not null default now()
);

insert into raw.orders (order_id, customer_id, order_status, ordered_at, updated_at)
select
    gs.order_id,
    1 + ((gs.order_id * 7) % 25) as customer_id,
    status.order_status,
    ordered_at.ts,
    -- least(...) : updated_at ne doit jamais depasser "maintenant",
    -- sinon le pattern incremental high-water-mark (module 05) casse
    -- (une commande "mise a jour dans le futur" bloque toute nouvelle
    -- commande inseree ensuite avec updated_at = now()).
    least(ordered_at.ts + status.settle_delay, now()) as updated_at
from generate_series(1, 90) as gs(order_id)
cross join lateral (
    select
        date_trunc('day', now())
            - ((90 - gs.order_id) || ' days')::interval
            + ((gs.order_id % 24) || ' hours')::interval as ts
) as ordered_at
cross join lateral (
    select
        case
            when gs.order_id % 12 between 0 and 6 then 'completed'
            when gs.order_id % 12 in (7, 8)        then 'shipped'
            when gs.order_id % 12 = 9              then 'placed'
            when gs.order_id % 12 = 10             then 'returned'
            else 'cancelled'
        end as order_status,
        case
            when gs.order_id % 12 between 0 and 6 then interval '2 days'
            when gs.order_id % 12 in (7, 8)        then interval '1 day'
            when gs.order_id % 12 = 10             then interval '5 days'
            else interval '0 hours'
        end as settle_delay
) as status;

-- =====================================================================
-- raw.order_items  (1 a 3 lignes par commande)
-- =====================================================================
drop table if exists raw.order_items cascade;
create table raw.order_items (
    order_item_id    integer primary key,
    order_id         integer not null references raw.orders(order_id),
    product_id       integer not null references raw.products(product_id),
    quantity         integer not null,
    unit_price_cents integer not null,
    _loaded_at       timestamp not null default now()
);

insert into raw.order_items (order_item_id, order_id, product_id, quantity, unit_price_cents)
select
    row_number() over (order by o.order_id, gs.item_index) as order_item_id,
    o.order_id,
    p.product_id,
    (1 + ((o.order_id + gs.item_index) % 3)) as quantity,
    p.unit_price_cents
from raw.orders o
cross join lateral generate_series(1, 1 + (o.order_id % 3)) as gs(item_index)
join raw.products p
    on p.product_id = 1 + ((o.order_id * 3 + gs.item_index * 5) % 15)
order by o.order_id, gs.item_index;

-- =====================================================================
-- raw.payments  (1 paiement par commande)
-- =====================================================================
drop table if exists raw.payments cascade;
create table raw.payments (
    payment_id     integer primary key,
    order_id       integer not null references raw.orders(order_id),
    payment_method text not null,
    amount_cents   integer not null,
    payment_status text not null,
    paid_at        timestamp not null,
    _loaded_at     timestamp not null default now()
);

insert into raw.payments (payment_id, order_id, payment_method, amount_cents, payment_status, paid_at)
select
    o.order_id as payment_id,
    o.order_id,
    (array['credit_card', 'paypal', 'bank_transfer', 'gift_card'])[1 + (o.order_id % 4)] as payment_method,
    coalesce(totals.total_cents, 0) as amount_cents,
    case o.order_status
        when 'returned'  then 'refunded'
        when 'cancelled' then 'failed'
        else 'success'
    end as payment_status,
    o.ordered_at + interval '10 minutes' as paid_at
from raw.orders o
left join (
    select order_id, sum(quantity * unit_price_cents) as total_cents
    from raw.order_items
    group by order_id
) as totals on totals.order_id = o.order_id;

-- =====================================================================
-- raw.returns  (utilise au module 12 - projet capstone)
-- Seules les commandes "returned" ont une ligne de retour, sur un
-- sous-ensemble de leurs articles.
-- =====================================================================
drop table if exists raw.returns cascade;
create table raw.returns (
    return_id          integer primary key,
    order_item_id      integer not null references raw.order_items(order_item_id),
    reason             text not null,
    refund_amount_cents integer not null,
    returned_at        timestamp not null,
    _loaded_at         timestamp not null default now()
);

insert into raw.returns (return_id, order_item_id, reason, refund_amount_cents, returned_at)
select
    row_number() over (order by oi.order_item_id) as return_id,
    oi.order_item_id,
    (array['damaged', 'wrong_item', 'no_longer_needed', 'defective'])[1 + (oi.order_item_id % 4)] as reason,
    oi.quantity * oi.unit_price_cents as refund_amount_cents,
    o.updated_at + interval '2 hours' as returned_at
from raw.order_items oi
join raw.orders o on o.order_id = oi.order_id
where o.order_status = 'returned';

analyze raw.customers;
analyze raw.products;
analyze raw.orders;
analyze raw.order_items;
analyze raw.payments;
analyze raw.returns;
