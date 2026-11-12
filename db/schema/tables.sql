CREATE SCHEMA IF NOT EXISTS bulatov_food;
SET search_path TO bulatov_food, exts;

-- Создание ENUM типов
CREATE TYPE restaurant_status AS ENUM ('активен', 'неактивен');
CREATE TYPE product_status AS ENUM ('доступно', 'нет_в_наличии', 'архив');
CREATE TYPE courier_status AS ENUM ('свободен', 'занят', 'на_доставке', 'уволен');
CREATE TYPE order_status AS ENUM ('создан', 'готовится', 'в_доставке', 'доставлен', 'отменён');
CREATE TYPE pay_status AS ENUM ('ожидает', 'оплачен', 'ошибка');
CREATE TYPE payment_status AS ENUM ('успех', 'ошибка', 'в_обработке');
CREATE TYPE payment_type AS ENUM ('карта', 'наличные', 'безнал');
CREATE TYPE review_entity_type AS ENUM ('блюдо', 'ресторан', 'заказ');

-- Сущности без внешних ключей
CREATE TABLE client (
    client_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    login varchar(100) UNIQUE NOT NULL,
    password varchar(32) NOT NULL,
    phone_number varchar(20) UNIQUE NOT NULL
);

CREATE TABLE address (
    address_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    street varchar(255) NOT NULL,
    house_number varchar(50) NOT NULL,
    apartment_office varchar(50)
);

CREATE TABLE product_category (
    product_category_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_category_name varchar(255) NOT NULL
);

CREATE TABLE courier (
    courier_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    "FIO" varchar(255) NOT NULL,
    phone_number varchar(20) UNIQUE NOT NULL,
    status courier_status NOT NULL DEFAULT 'свободен',
    hire_date date NOT NULL,
    dismissal_date date,
    coefficient numeric(2,1) NOT NULL DEFAULT 0.1 CHECK (coefficient BETWEEN 0.1 AND 0.5),
    CHECK (dismissal_date IS NULL OR dismissal_date >= hire_date)
);

-- Сущности с внешними ключами
CREATE TABLE client_address (
    client_id uuid REFERENCES client(client_id) ON DELETE CASCADE,
    address_id uuid REFERENCES address(address_id) ON DELETE RESTRICT,
    PRIMARY KEY (client_id, address_id)
);

CREATE TABLE restaurant (
    restaurant_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    restaurant_name varchar(255) NOT NULL,
    address_id uuid UNIQUE NOT NULL REFERENCES address(address_id) ON DELETE RESTRICT,
    description text,
    work_start time NOT NULL,
    work_end time NOT NULL,
    company_details text NOT NULL,
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status restaurant_status NOT NULL DEFAULT 'активен',
    CHECK (work_end > work_start)
);

CREATE TABLE courier_pay (
    year int NOT NULL,
    month int NOT NULL,
    courier_id uuid REFERENCES courier(courier_id) ON DELETE CASCADE,
    amount numeric(12,2) NOT NULL CHECK (amount >= 0),
    coefficient_used numeric(2,1) NOT NULL CHECK (coefficient_used BETWEEN 0.1 AND 0.5),
    PRIMARY KEY (year, month, courier_id)
);

CREATE TABLE product (
    product_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    product_name varchar(255) NOT NULL,
    product_category_id uuid NOT NULL REFERENCES product_category(product_category_id) ON DELETE RESTRICT,
    price numeric(10,2) NOT NULL CHECK (price >= 0),
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id) ON DELETE CASCADE,
    photo_url text,
    rating numeric(3,2) CHECK (rating BETWEEN 0 AND 5),
    status product_status NOT NULL DEFAULT 'доступно',
    description text
);

CREATE TABLE "order" (
    order_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    courier_id uuid NOT NULL REFERENCES courier(courier_id) ON DELETE RESTRICT,
    client_id uuid NOT NULL REFERENCES client(client_id) ON DELETE RESTRICT,
    address_id uuid NOT NULL REFERENCES address(address_id) ON DELETE RESTRICT,
    restaurant_id uuid NOT NULL REFERENCES restaurant(restaurant_id) ON DELETE RESTRICT,
    order_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    delivery_timestamp timestamp,
    order_amount numeric(12,2) NOT NULL,
    commission numeric(12,2) GENERATED ALWAYS AS (ROUND(order_amount * 0.10, 2)) STORED,
    total_amount numeric(12,2) GENERATED ALWAYS AS (order_amount + ROUND(order_amount * 0.10, 2)) STORED,
    status order_status NOT NULL DEFAULT 'создан',
    pay_status pay_status NOT NULL DEFAULT 'ожидает',
    description text,
    CHECK (total_amount >= 1000),
    CHECK (delivery_timestamp IS NULL OR delivery_timestamp >= order_timestamp)
);

CREATE TABLE payment (
    payment_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    order_id uuid NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    payment_type payment_type NOT NULL,
    amount numeric(12,2) NOT NULL,
    transaction_id varchar(255) UNIQUE NOT NULL,
    transaction_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    status payment_status NOT NULL DEFAULT 'в_обработке'
);

CREATE TABLE order_structure (
    order_id uuid REFERENCES "order"(order_id) ON DELETE CASCADE,
    product_id uuid REFERENCES product(product_id) ON DELETE RESTRICT,
    quantity numeric(10,3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (order_id, product_id)
);

CREATE TABLE review (
    review_id uuid PRIMARY KEY DEFAULT exts.uuid_generate_v4(),
    client_id uuid NOT NULL REFERENCES client(client_id) ON DELETE CASCADE,
    review_timestamp timestamp NOT NULL DEFAULT localtimestamp,
    entity_id uuid NOT NULL,
    entity_type review_entity_type NOT NULL,
    order_id uuid NOT NULL REFERENCES "order"(order_id) ON DELETE CASCADE,
    description text NOT NULL,
    photo_url text,
    rating int NOT NULL CHECK (rating BETWEEN 1 AND 5)
);
