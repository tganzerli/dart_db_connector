-- TPC-C reduced schema for benchmark — MySQL (InnoDB) port of
-- tpcc_schema.sql.  / A.7. Same 9 canonical tables and simplifications
-- (single S_DIST_INFO; C_DATA/S_DATA/H_DATA omitted).
--
-- MySQL type mapping vs the Postgres schema:
--   int4         -> INT
--   numeric(p,s) -> DECIMAL(p,s)
--   char(n)      -> CHAR(n)      varchar(n) -> VARCHAR(n)
--   timestamptz  -> DATETIME     (MySQL has no timestamptz; naive datetime)
-- DROP CASCADE is not a MySQL keyword; disable FK checks around the drops.

SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS order_line;
DROP TABLE IF EXISTS new_order;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS history;
DROP TABLE IF EXISTS customer;
DROP TABLE IF EXISTS district;
DROP TABLE IF EXISTS warehouse;
DROP TABLE IF EXISTS stock;
DROP TABLE IF EXISTS item;
SET FOREIGN_KEY_CHECKS = 1;

CREATE TABLE warehouse (
  w_id      INT           PRIMARY KEY,
  w_name    VARCHAR(10)   NOT NULL,
  w_street  VARCHAR(40)   NOT NULL,
  w_city    VARCHAR(20)   NOT NULL,
  w_state   CHAR(2)       NOT NULL,
  w_zip     CHAR(9)       NOT NULL,
  w_tax     DECIMAL(4,4)  NOT NULL,
  w_ytd     DECIMAL(12,2) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE district (
  d_w_id        INT           NOT NULL,
  d_id          INT           NOT NULL,
  d_name        VARCHAR(10)   NOT NULL,
  d_street      VARCHAR(40)   NOT NULL,
  d_city        VARCHAR(20)   NOT NULL,
  d_state       CHAR(2)       NOT NULL,
  d_zip         CHAR(9)       NOT NULL,
  d_tax         DECIMAL(4,4)  NOT NULL,
  d_ytd         DECIMAL(12,2) NOT NULL,
  d_next_o_id   INT           NOT NULL,
  PRIMARY KEY (d_w_id, d_id),
  FOREIGN KEY (d_w_id) REFERENCES warehouse(w_id)
) ENGINE=InnoDB;

CREATE TABLE customer (
  c_w_id          INT           NOT NULL,
  c_d_id          INT           NOT NULL,
  c_id            INT           NOT NULL,
  c_first         VARCHAR(16)   NOT NULL,
  c_middle        CHAR(2)       NOT NULL,
  c_last          VARCHAR(16)   NOT NULL,
  c_street        VARCHAR(40)   NOT NULL,
  c_city          VARCHAR(20)   NOT NULL,
  c_state         CHAR(2)       NOT NULL,
  c_zip           CHAR(9)       NOT NULL,
  c_since         DATETIME      NOT NULL,
  c_credit        CHAR(2)       NOT NULL,
  c_credit_lim    DECIMAL(12,2) NOT NULL,
  c_discount      DECIMAL(4,4)  NOT NULL,
  c_balance       DECIMAL(12,2) NOT NULL,
  c_ytd_payment   DECIMAL(12,2) NOT NULL,
  c_payment_cnt   INT           NOT NULL,
  c_delivery_cnt  INT           NOT NULL,
  PRIMARY KEY (c_w_id, c_d_id, c_id),
  KEY idx_customer_last (c_w_id, c_d_id, c_last),
  FOREIGN KEY (c_w_id, c_d_id) REFERENCES district(d_w_id, d_id)
) ENGINE=InnoDB;

CREATE TABLE history (
  h_c_id    INT          NOT NULL,
  h_c_d_id  INT          NOT NULL,
  h_c_w_id  INT          NOT NULL,
  h_d_id    INT          NOT NULL,
  h_w_id    INT          NOT NULL,
  h_date    DATETIME     NOT NULL,
  h_amount  DECIMAL(6,2) NOT NULL,
  h_data    VARCHAR(24)  NOT NULL
) ENGINE=InnoDB;

CREATE TABLE orders (
  o_w_id        INT      NOT NULL,
  o_d_id        INT      NOT NULL,
  o_id          INT      NOT NULL,
  o_c_id        INT      NOT NULL,
  o_entry_d     DATETIME NOT NULL,
  o_carrier_id  INT,
  o_ol_cnt      INT      NOT NULL,
  o_all_local   INT      NOT NULL,
  PRIMARY KEY (o_w_id, o_d_id, o_id),
  KEY idx_orders_customer (o_w_id, o_d_id, o_c_id, o_id),
  FOREIGN KEY (o_w_id, o_d_id, o_c_id) REFERENCES customer(c_w_id, c_d_id, c_id)
) ENGINE=InnoDB;

CREATE TABLE new_order (
  no_w_id  INT NOT NULL,
  no_d_id  INT NOT NULL,
  no_o_id  INT NOT NULL,
  PRIMARY KEY (no_w_id, no_d_id, no_o_id),
  FOREIGN KEY (no_w_id, no_d_id, no_o_id) REFERENCES orders(o_w_id, o_d_id, o_id)
) ENGINE=InnoDB;

CREATE TABLE order_line (
  ol_w_id         INT          NOT NULL,
  ol_d_id         INT          NOT NULL,
  ol_o_id         INT          NOT NULL,
  ol_number       INT          NOT NULL,
  ol_i_id         INT          NOT NULL,
  ol_supply_w_id  INT          NOT NULL,
  ol_delivery_d   DATETIME,
  ol_quantity     INT          NOT NULL,
  ol_amount       DECIMAL(6,2) NOT NULL,
  ol_dist_info    CHAR(24)     NOT NULL,
  PRIMARY KEY (ol_w_id, ol_d_id, ol_o_id, ol_number),
  FOREIGN KEY (ol_w_id, ol_d_id, ol_o_id) REFERENCES orders(o_w_id, o_d_id, o_id)
) ENGINE=InnoDB;

CREATE TABLE item (
  i_id     INT          PRIMARY KEY,
  i_im_id  INT          NOT NULL,
  i_name   VARCHAR(24)  NOT NULL,
  i_price  DECIMAL(5,2) NOT NULL,
  i_data   VARCHAR(50)  NOT NULL
) ENGINE=InnoDB;

CREATE TABLE stock (
  s_w_id        INT          NOT NULL,
  s_i_id        INT          NOT NULL,
  s_quantity    INT          NOT NULL,
  s_dist_info   CHAR(24)     NOT NULL,
  s_ytd         DECIMAL(8,0) NOT NULL,
  s_order_cnt   INT          NOT NULL,
  s_remote_cnt  INT          NOT NULL,
  PRIMARY KEY (s_w_id, s_i_id),
  FOREIGN KEY (s_w_id) REFERENCES warehouse(w_id),
  FOREIGN KEY (s_i_id) REFERENCES item(i_id)
) ENGINE=InnoDB;
