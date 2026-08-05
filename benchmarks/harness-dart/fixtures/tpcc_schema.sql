-- TPC-C reduced schema for benchmark.
-- 9 canonical tables; some columns simplified per
--   * STOCK uses a single S_DIST_INFO instead of S_DIST_01..10.
--   * C_DATA, S_DATA, H_DATA omitted (not touched by the 5 transactions).
-- Identifiers and SQL keywords in English (pub.dev convention) but
-- semantics tracking the spec.

DROP TABLE IF EXISTS order_line CASCADE;
DROP TABLE IF EXISTS new_order CASCADE;
DROP TABLE IF EXISTS orders CASCADE;
DROP TABLE IF EXISTS history CASCADE;
DROP TABLE IF EXISTS customer CASCADE;
DROP TABLE IF EXISTS district CASCADE;
DROP TABLE IF EXISTS warehouse CASCADE;
DROP TABLE IF EXISTS stock CASCADE;
DROP TABLE IF EXISTS item CASCADE;

CREATE TABLE warehouse (
  w_id      int4         PRIMARY KEY,
  w_name    varchar(10)  NOT NULL,
  w_street  varchar(40)  NOT NULL,
  w_city    varchar(20)  NOT NULL,
  w_state   char(2)      NOT NULL,
  w_zip     char(9)      NOT NULL,
  w_tax     numeric(4,4) NOT NULL,
  w_ytd     numeric(12,2) NOT NULL
);

CREATE TABLE district (
  d_w_id        int4         NOT NULL,
  d_id          int4         NOT NULL,
  d_name        varchar(10)  NOT NULL,
  d_street      varchar(40)  NOT NULL,
  d_city        varchar(20)  NOT NULL,
  d_state       char(2)      NOT NULL,
  d_zip         char(9)      NOT NULL,
  d_tax         numeric(4,4) NOT NULL,
  d_ytd         numeric(12,2) NOT NULL,
  d_next_o_id   int4         NOT NULL,
  PRIMARY KEY (d_w_id, d_id),
  FOREIGN KEY (d_w_id) REFERENCES warehouse(w_id)
);

CREATE TABLE customer (
  c_w_id          int4         NOT NULL,
  c_d_id          int4         NOT NULL,
  c_id            int4         NOT NULL,
  c_first         varchar(16)  NOT NULL,
  c_middle        char(2)      NOT NULL,
  c_last          varchar(16)  NOT NULL,
  c_street        varchar(40)  NOT NULL,
  c_city          varchar(20)  NOT NULL,
  c_state         char(2)      NOT NULL,
  c_zip           char(9)      NOT NULL,
  c_since         timestamptz  NOT NULL,
  c_credit        char(2)      NOT NULL,
  c_credit_lim    numeric(12,2) NOT NULL,
  c_discount      numeric(4,4) NOT NULL,
  c_balance       numeric(12,2) NOT NULL,
  c_ytd_payment   numeric(12,2) NOT NULL,
  c_payment_cnt   int4         NOT NULL,
  c_delivery_cnt  int4         NOT NULL,
  PRIMARY KEY (c_w_id, c_d_id, c_id),
  FOREIGN KEY (c_w_id, c_d_id) REFERENCES district(d_w_id, d_id)
);

CREATE INDEX idx_customer_last ON customer (c_w_id, c_d_id, c_last);

CREATE TABLE history (
  h_c_id    int4         NOT NULL,
  h_c_d_id  int4         NOT NULL,
  h_c_w_id  int4         NOT NULL,
  h_d_id    int4         NOT NULL,
  h_w_id    int4         NOT NULL,
  h_date    timestamptz  NOT NULL,
  h_amount  numeric(6,2) NOT NULL,
  h_data    varchar(24)  NOT NULL
);

CREATE TABLE orders (
  o_w_id        int4         NOT NULL,
  o_d_id        int4         NOT NULL,
  o_id          int4         NOT NULL,
  o_c_id        int4         NOT NULL,
  o_entry_d     timestamptz  NOT NULL,
  o_carrier_id  int4,
  o_ol_cnt      int4         NOT NULL,
  o_all_local   int4         NOT NULL,
  PRIMARY KEY (o_w_id, o_d_id, o_id),
  FOREIGN KEY (o_w_id, o_d_id, o_c_id) REFERENCES customer(c_w_id, c_d_id, c_id)
);

CREATE INDEX idx_orders_customer ON orders (o_w_id, o_d_id, o_c_id, o_id);

CREATE TABLE new_order (
  no_w_id  int4 NOT NULL,
  no_d_id  int4 NOT NULL,
  no_o_id  int4 NOT NULL,
  PRIMARY KEY (no_w_id, no_d_id, no_o_id),
  FOREIGN KEY (no_w_id, no_d_id, no_o_id) REFERENCES orders(o_w_id, o_d_id, o_id)
);

CREATE TABLE order_line (
  ol_w_id         int4         NOT NULL,
  ol_d_id         int4         NOT NULL,
  ol_o_id         int4         NOT NULL,
  ol_number       int4         NOT NULL,
  ol_i_id         int4         NOT NULL,
  ol_supply_w_id  int4         NOT NULL,
  ol_delivery_d   timestamptz,
  ol_quantity     int4         NOT NULL,
  ol_amount       numeric(6,2) NOT NULL,
  ol_dist_info    char(24)     NOT NULL,
  PRIMARY KEY (ol_w_id, ol_d_id, ol_o_id, ol_number),
  FOREIGN KEY (ol_w_id, ol_d_id, ol_o_id) REFERENCES orders(o_w_id, o_d_id, o_id)
);

CREATE TABLE item (
  i_id     int4         PRIMARY KEY,
  i_im_id  int4         NOT NULL,
  i_name   varchar(24)  NOT NULL,
  i_price  numeric(5,2) NOT NULL,
  i_data   varchar(50)  NOT NULL
);

CREATE TABLE stock (
  s_w_id        int4         NOT NULL,
  s_i_id        int4         NOT NULL,
  s_quantity    int4         NOT NULL,
  s_dist_info   char(24)     NOT NULL,
  s_ytd         numeric(8,0) NOT NULL,
  s_order_cnt   int4         NOT NULL,
  s_remote_cnt  int4         NOT NULL,
  PRIMARY KEY (s_w_id, s_i_id),
  FOREIGN KEY (s_w_id) REFERENCES warehouse(w_id),
  FOREIGN KEY (s_i_id) REFERENCES item(i_id)
);
