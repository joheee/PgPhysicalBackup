-- Drill sample data, loaded into appdb on the throwaway drill-source database.
-- pgbench tables are added by `pgbench -i` in drill/run.sh.

CREATE TABLE orders (
    id         bigserial PRIMARY KEY,
    customer   text          NOT NULL,
    amount     numeric(10,2) NOT NULL,
    created_at timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX orders_customer_idx ON orders (customer);
INSERT INTO orders (customer, amount)
SELECT 'customer-' || g, (g % 500) + 0.99 FROM generate_series(1, 1000) AS g;

-- One row every second while the drill runs (see run.sh). After a crash, the
-- newest canary row in the restored copy shows how much data was lost (RPO).
CREATE TABLE canary (
    id bigserial   PRIMARY KEY,
    ts timestamptz NOT NULL DEFAULT clock_timestamp()
);

-- The "bad migration" in the named restore point scenario adds a row here.
CREATE TABLE schema_migrations (
    version    text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT now()
);
