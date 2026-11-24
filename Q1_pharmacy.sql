-- =====================================================================
-- ICT371 Advanced Database | Question 1: Pharmacy Stock and Daily Sales
-- Dialect: PostgreSQL (PL/pgSQL). Scheduling uses the pg_cron extension.
-- =====================================================================

-- (a) DATABASE AND SEED DATA ------------------------------------------
DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

CREATE TABLE medicines (
    medicine_id   SERIAL        PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL        PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines (medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL
);

CREATE TABLE stock_audit (
    audit_id    SERIAL    PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines (medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE          PRIMARY KEY,
    total_qty    INTEGER       NOT NULL,
    total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  50),
    ('Ibuprofen 400mg',   4.00,  30),
    ('Oral Rehydration Salts', 1.50, 12);

-- (b) FUNCTION ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- (c) PROCEDURE --------------------------------------------------------
-- A raised exception aborts the whole CALL, so an invalid sale leaves
-- both medicines and sales unchanged. The row lock prevents overselling
-- when two sales happen at the same moment.
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INTEGER, p_quantity INTEGER, p_sold_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;
    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity      -- deducted exactly once
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- (d) TRIGGER ----------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NULL;   -- return value is ignored for AFTER row triggers
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- (a) CONTINUED: LOAD SIX VALID SALES THROUGH THE PROCEDURE ------------
-- (Loaded after the trigger so that every stock change is audited.)
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2,  5, CURRENT_DATE - 1);
CALL pr_record_sale(3,  8, CURRENT_DATE);
CALL pr_record_sale(4,  5, CURRENT_DATE);
CALL pr_record_sale(3,  4, CURRENT_DATE);

SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Test of function and of rejected sale (nothing should change)
SELECT fn_sale_value(2, 3) AS value_of_three_amoxicillin;
-- CALL pr_record_sale(1, 9999, CURRENT_DATE);   -- fails: insufficient stock
-- CALL pr_record_sale(99, 1, CURRENT_DATE);     -- fails: unknown medicine

-- (e) VIEW -------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;   -- queried after the sales above

-- (f) INDEX ------------------------------------------------------------
-- Justification: the query filters on one medicine (equality) and a
-- sold_on range. A composite index with the equality column first and the
-- range column second lets PostgreSQL jump to the medicine and read its
-- dates in order without scanning the whole sales table.
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- only so the plan is visible on a tiny table
EXPLAIN
SELECT *
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) SCHEDULED JOB ----------------------------------------------------
-- Rerun safe: INSERT ... ON CONFLICT replaces the day's row, so totals are
-- recalculated from the sales table and never added twice.
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
    SET total_qty    = EXCLUDED.total_qty,
        total_amount = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);   -- rerun: still one row, same totals
SELECT * FROM daily_sales;

-- pg_cron must be listed in shared_preload_libraries and created once:
-- CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'refresh_sales_daily',
    '15 0 * * *',                                   -- every day at 00:15
    $job$CALL pr_refresh_sales(CURRENT_DATE - 1)$job$
);
