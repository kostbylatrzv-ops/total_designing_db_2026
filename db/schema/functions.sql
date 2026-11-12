SET search_path TO bulatov_food, exts;

-- FOOD-103: Очистка тестовых данных
CREATE OR REPLACE PROCEDURE erase_test_data()
LANGUAGE plpgsql AS $$
BEGIN
    TRUNCATE TABLE review, order_structure, payment, "order", product, courier_pay, restaurant, client_address, courier, product_category, address, client CASCADE;
END;
$$;

-- FOOD-104: Добавление блюда
CREATE OR REPLACE PROCEDURE add_product(
    p_product_name varchar,
    p_product_category_id uuid,
    p_price numeric,
    p_restaurant_id uuid,
    p_photo_url text DEFAULT NULL,
    p_rating numeric DEFAULT NULL,
    p_status product_status DEFAULT 'доступно',
    p_description text DEFAULT NULL
)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO product (product_name, product_category_id, price, restaurant_id, photo_url, rating, status, description)
    VALUES (p_product_name, p_product_category_id, p_price, p_restaurant_id, p_photo_url, p_rating, p_status, p_description);
END;
$$;

-- FOOD-105: Триггер пересчёта рейтинга (BR-9.6)
CREATE OR REPLACE FUNCTION rating_change()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
        IF NEW.entity_type = 'блюдо' THEN
            UPDATE product SET rating = (SELECT AVG(rating) FROM review WHERE entity_type = 'блюдо' AND entity_id = NEW.entity_id) WHERE product_id = NEW.entity_id;
        ELSIF NEW.entity_type = 'ресторан' THEN
            UPDATE restaurant SET rating = (SELECT AVG(rating) FROM review WHERE entity_type = 'ресторан' AND entity_id = NEW.entity_id) WHERE restaurant_id = NEW.entity_id;
        END IF;
    END IF;

    IF TG_OP = 'DELETE' OR (TG_OP = 'UPDATE' AND (OLD.entity_id != NEW.entity_id OR OLD.entity_type != NEW.entity_type)) THEN
        IF OLD.entity_type = 'блюдо' THEN
            UPDATE product SET rating = (SELECT AVG(rating) FROM review WHERE entity_type = 'блюдо' AND entity_id = OLD.entity_id) WHERE product_id = OLD.entity_id;
        ELSIF OLD.entity_type = 'ресторан' THEN
            UPDATE restaurant SET rating = (SELECT AVG(rating) FROM review WHERE entity_type = 'ресторан' AND entity_id = OLD.entity_id) WHERE restaurant_id = OLD.entity_id;
        END IF;
    END IF;

    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_review_rating_change ON review;
CREATE TRIGGER trg_review_rating_change
AFTER INSERT OR UPDATE OR DELETE ON review
FOR EACH ROW EXECUTE FUNCTION rating_change();

-- FOOD-106: Статистика по ресторанам
CREATE OR REPLACE FUNCTION get_statistic()
RETURNS TABLE(restaurant_name varchar, best_product_name varchar, total_amount numeric, avg_amount numeric, best_user varchar) AS $$
BEGIN
    RETURN QUERY
    WITH deliv AS (
        SELECT o.order_id, o.restaurant_id, o.client_id, o.total_amount
        FROM "order" o WHERE o.status = 'доставлен'
    ),
    best_prods AS (
        SELECT DISTINCT ON (o.restaurant_id)
            o.restaurant_id, p.product_name
        FROM deliv o
        JOIN order_structure os ON o.order_id = os.order_id
        JOIN product p ON os.product_id = p.product_id
        GROUP BY o.restaurant_id, p.product_id, p.product_name
        ORDER BY o.restaurant_id, SUM(os.quantity) DESC
    ),
    best_users AS (
        SELECT DISTINCT ON (o.restaurant_id)
            o.restaurant_id, c.login
        FROM deliv o
        JOIN client c ON o.client_id = c.client_id
        GROUP BY o.restaurant_id, c.client_id, c.login
        ORDER BY o.restaurant_id, COUNT(o.order_id) DESC
    )
    SELECT 
        r.restaurant_name::varchar,
        bp.product_name::varchar,
        COALESCE(SUM(o.total_amount), 0)::numeric,
        COALESCE(AVG(o.total_amount), 0)::numeric,
        bu.login::varchar
    FROM restaurant r
    LEFT JOIN deliv o ON r.restaurant_id = o.restaurant_id
    LEFT JOIN best_prods bp ON r.restaurant_id = bp.restaurant_id
    LEFT JOIN best_users bu ON r.restaurant_id = bu.restaurant_id
    GROUP BY r.restaurant_id, r.restaurant_name, bp.product_name, bu.login;
END;
$$ LANGUAGE plpgsql;

-- FOOD-107: Зарплата курьеров
CREATE OR REPLACE PROCEDURE courier_salary()
LANGUAGE plpgsql AS $$
DECLARE
    v_year INT := EXTRACT(YEAR FROM CURRENT_DATE);
    v_month INT := EXTRACT(MONTH FROM CURRENT_DATE);
BEGIN
    INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
    SELECT 
        v_year, 
        v_month, 
        c.courier_id,
        COALESCE(c.coefficient * SUM(o.commission), 0),
        c.coefficient
    FROM courier c
    LEFT JOIN "order" o ON c.courier_id = o.courier_id 
        AND o.status = 'доставлен' 
        AND EXTRACT(YEAR FROM o.order_timestamp) = v_year 
        AND EXTRACT(MONTH FROM o.order_timestamp) = v_month
    GROUP BY c.courier_id, c.coefficient
    ON CONFLICT (year, month, courier_id) DO UPDATE 
    SET amount = EXCLUDED.amount, coefficient_used = EXCLUDED.coefficient_used;

    UPDATE courier c
    SET coefficient = CASE 
        WHEN deliv_count <= 150 THEN 0.1
        WHEN deliv_count <= 250 THEN 0.2
        WHEN deliv_count <= 500 THEN 0.3
        ELSE 0.5
    END
    FROM (
        SELECT courier_id, COUNT(order_id) as deliv_count
        FROM "order"
        WHERE status = 'доставлен' 
          AND EXTRACT(YEAR FROM order_timestamp) = v_year 
          AND EXTRACT(MONTH FROM order_timestamp) = v_month
        GROUP BY courier_id
    ) stats
    WHERE c.courier_id = stats.courier_id AND c.status != 'уволен';
END;
$$;

-- FOOD-108: Отчёт «сколько денег»
CREATE OR REPLACE VIEW how_much_money AS
WITH RECURSIVE
min_max_dates AS (
    SELECT 
        date_trunc('month', MIN(order_timestamp)) AS start_m,
        date_trunc('month', MAX(order_timestamp)) AS end_m
    FROM "order" WHERE status = 'доставлен'
),
months_cte AS (
    SELECT start_m AS m FROM min_max_dates
    UNION ALL
    SELECT m + interval '1 month' FROM months_cte, min_max_dates WHERE m < end_m
),
monthly_totals AS (
    SELECT 
        date_trunc('month', order_timestamp) AS m,
        SUM(order_amount) AS sum_no_commission,
        SUM(total_amount) AS sum_with_commission
    FROM "order"
    WHERE status = 'доставлен'
    GROUP BY date_trunc('month', order_timestamp)
),
pay_totals AS (
    SELECT 
        make_date(year, month, 1) AS m,
        SUM(amount) AS pay_sum
    FROM courier_pay
    GROUP BY year, month
),
combined AS (
    SELECT 
        to_char(mc.m, 'YYYY-MM') AS year_month,
        COALESCE(mt.sum_no_commission, 0) AS sum_no_commission,
        COALESCE(mt.sum_with_commission, 0) AS sum_with_commission,
        COALESCE(mt.sum_with_commission, 0) - COALESCE(mt.sum_no_commission, 0) AS commission,
        COALESCE(pt.pay_sum, 0) AS courier_pay
    FROM months_cte mc
    LEFT JOIN monthly_totals mt ON mc.m = mt.m
    LEFT JOIN pay_totals pt ON mc.m = pt.m
)
SELECT 
    year_month::text,
    sum_no_commission,
    sum_with_commission,
    commission,
    LAG(commission) OVER (ORDER BY year_month) AS prev_commission,
    commission - LAG(commission) OVER (ORDER BY year_month) AS commission_diff,
    courier_pay,
    commission - courier_pay AS net_profit
FROM combined;

-- FOOD-102: Генератор тестовых данных
CREATE OR REPLACE PROCEDURE insert_test_data(p_value INT)
LANGUAGE plpgsql AS $$
DECLARE
    v_clients uuid[];
    v_addresses uuid[];
    v_couriers uuid[];
    v_restaurants uuid[];
    v_categories uuid[];
    v_products uuid[];
    v_orders uuid[];
    i INT;
    v_month_start date;
    v_order_ts timestamp;
BEGIN
    CALL erase_test_data();

    FOR i IN 1..(p_value * 5) LOOP
        INSERT INTO address (street, house_number) VALUES ('Улица ' || i, i::varchar) RETURNING address_id INTO v_addresses[i];
    END LOOP;

    FOR i IN 1..p_value LOOP
        INSERT INTO product_category (product_category_name) VALUES ('Категория ' || i) RETURNING product_category_id INTO v_categories[i];
    END LOOP;

    FOR i IN 1..p_value LOOP
        INSERT INTO client (login, password, phone_number) 
        VALUES ('client_' || i || '_' || md5(random()::text), md5('pass'::text), '7900' || lpad(i::text, 6, '0'))
        RETURNING client_id INTO v_clients[i];
        
        INSERT INTO client_address (client_id, address_id) VALUES (v_clients[i], v_addresses[p_value + (i-1)*4 + 1]);
    END LOOP;

    FOR i IN 1..p_value LOOP
        INSERT INTO courier ("FIO", phone_number, hire_date, coefficient) 
        VALUES ('Курьер ' || i, '7911' || lpad(i::text, 6, '0'), CURRENT_DATE - 200, 0.1) RETURNING courier_id INTO v_couriers[i];
    END LOOP;

    FOR i IN 1..p_value LOOP
        INSERT INTO restaurant (restaurant_name, address_id, work_start, work_end, company_details) 
        VALUES ('Ресторан ' || i, v_addresses[i], '09:00', '23:00', 'ИНН ' || i) RETURNING restaurant_id INTO v_restaurants[i];
    END LOOP;

    FOR i IN 1..(p_value * 5) LOOP
        INSERT INTO product (product_name, product_category_id, price, restaurant_id) 
        VALUES ('Блюдо ' || i, v_categories[1 + (i % p_value)], 500 + (i * 10), v_restaurants[1 + (i % p_value)]) RETURNING product_id INTO v_products[i];
    END LOOP;

    FOR i IN 1..(p_value * 5) LOOP
        v_order_ts := localtimestamp - (random() * 180)::int * interval '1 day';
        INSERT INTO "order" (courier_id, client_id, address_id, restaurant_id, order_timestamp, delivery_timestamp, order_amount, status, pay_status) 
        VALUES (
            v_couriers[1 + (i % p_value)], v_clients[1 + (i % p_value)], v_addresses[p_value + (1 + (i % p_value) - 1)*4 + 1], 
            v_restaurants[1 + (i % p_value)], v_order_ts, v_order_ts + interval '1 hour', 1500, 'доставлен', 'оплачен'
        ) RETURNING order_id INTO v_orders[i];

        INSERT INTO order_structure (order_id, product_id, quantity) VALUES (v_orders[i], v_products[1 + (i % p_value)], 1);
        INSERT INTO payment (order_id, payment_type, amount, transaction_id, status) VALUES (v_orders[i], 'карта', 1650, md5(random()::text), 'успех');
        INSERT INTO review (client_id, entity_id, entity_type, order_id, description, rating) VALUES (v_clients[1 + (i % p_value)], v_products[1 + (i % p_value)], 'блюдо', v_orders[i], 'Вкусно', 5);
    END LOOP;

    FOR m IN 0..5 LOOP
        v_month_start := date_trunc('month', CURRENT_DATE - (m || ' months')::interval);
        INSERT INTO courier_pay (year, month, courier_id, amount, coefficient_used)
        SELECT EXTRACT(YEAR FROM v_month_start), EXTRACT(MONTH FROM v_month_start), c.courier_id, COALESCE(c.coefficient * SUM(o.commission), 0), c.coefficient
        FROM courier c LEFT JOIN "order" o ON c.courier_id = o.courier_id AND o.status = 'доставлен' AND EXTRACT(YEAR FROM o.order_timestamp) = EXTRACT(YEAR FROM v_month_start) AND EXTRACT(MONTH FROM o.order_timestamp) = EXTRACT(MONTH FROM v_month_start)
        GROUP BY c.courier_id, c.coefficient;
    END LOOP;
END;
$$;
