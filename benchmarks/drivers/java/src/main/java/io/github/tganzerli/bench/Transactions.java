package io.github.tganzerli.bench;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.Locale;

import io.github.tganzerli.bench.Mix.*;

public class Transactions {

    private static String esc(String s) { return s.replace("'", "''"); }
    private static String fmt2(double x) { return String.format(Locale.ROOT, "%.2f", x); }

    public static void newOrder(Connection conn, NewOrderParams p) throws Exception {
        conn.setAutoCommit(false);
        try (Statement st = conn.createStatement()) {
            try (ResultSet rs = st.executeQuery(
                    "SELECT c_discount, c_last, c_credit FROM customer " +
                    "WHERE c_w_id=" + p.wId + " AND c_d_id=" + p.dId + " AND c_id=" + p.cId)) {
                while (rs.next()) { rs.getString("c_last"); }
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT w_tax FROM warehouse WHERE w_id=" + p.wId)) {
                while (rs.next()) { rs.getDouble("w_tax"); }
            }
            int oId = -1;
            try (ResultSet rs = st.executeQuery(
                    "SELECT d_next_o_id, d_tax FROM district " +
                    "WHERE d_w_id=" + p.wId + " AND d_id=" + p.dId + " FOR UPDATE")) {
                if (rs.next()) oId = rs.getInt("d_next_o_id");
            }
            st.executeUpdate("UPDATE district SET d_next_o_id = d_next_o_id + 1 " +
                    "WHERE d_w_id=" + p.wId + " AND d_id=" + p.dId);

            int allLocal = 1;
            for (NewOrderLine l : p.lines) if (l.supplyWId != p.wId) { allLocal = 0; break; }
            st.executeUpdate(
                "INSERT INTO orders (o_w_id, o_d_id, o_id, o_c_id, o_entry_d, o_carrier_id, o_ol_cnt, o_all_local) " +
                "VALUES (" + p.wId + ", " + p.dId + ", " + oId + ", " + p.cId +
                ", NOW(), NULL, " + p.lines.size() + ", " + allLocal + ")");

            st.executeUpdate(
                "INSERT INTO new_order (no_w_id, no_d_id, no_o_id) " +
                "VALUES (" + p.wId + ", " + p.dId + ", " + oId + ")");

            for (int olNumber = 1; olNumber <= p.lines.size(); olNumber++) {
                NewOrderLine line = p.lines.get(olNumber - 1);
                double price;
                try (ResultSet rs = st.executeQuery(
                        "SELECT i_price, i_name, i_data FROM item WHERE i_id=" + line.iId)) {
                    rs.next();
                    price = rs.getDouble("i_price");
                }
                int sQty, sOrderCnt, sRemoteCnt;
                String sDist;
                double sYtd;
                try (ResultSet rs = st.executeQuery(
                        "SELECT s_quantity, s_dist_info, s_ytd, s_order_cnt, s_remote_cnt " +
                        "FROM stock WHERE s_w_id=" + line.supplyWId + " AND s_i_id=" + line.iId + " FOR UPDATE")) {
                    rs.next();
                    sQty = rs.getInt("s_quantity");
                    sDist = rs.getString("s_dist_info");
                    sYtd = rs.getDouble("s_ytd");
                    sOrderCnt = rs.getInt("s_order_cnt");
                    sRemoteCnt = rs.getInt("s_remote_cnt");
                }
                int newQty = (sQty - line.quantity >= 10) ? (sQty - line.quantity) : (sQty - line.quantity + 91);
                int remoteInc = (line.supplyWId == p.wId) ? 0 : 1;
                st.executeUpdate(
                    "UPDATE stock SET s_quantity=" + newQty +
                    ", s_ytd=" + fmt2(sYtd + line.quantity) +
                    ", s_order_cnt=" + (sOrderCnt + 1) +
                    ", s_remote_cnt=" + (sRemoteCnt + remoteInc) +
                    " WHERE s_w_id=" + line.supplyWId + " AND s_i_id=" + line.iId);

                double amount = line.quantity * price;
                String sDistEsc = esc(sDist);
                st.executeUpdate(
                    "INSERT INTO order_line (ol_w_id, ol_d_id, ol_o_id, ol_number, ol_i_id, ol_supply_w_id, ol_delivery_d, ol_quantity, ol_amount, ol_dist_info) " +
                    "VALUES (" + p.wId + ", " + p.dId + ", " + oId + ", " + olNumber + ", " +
                    line.iId + ", " + line.supplyWId + ", NULL, " + line.quantity + ", " +
                    fmt2(amount) + ", '" + sDistEsc + "')");
            }
            conn.commit();
        } catch (Exception e) {
            conn.rollback();
            throw e;
        }
    }

    public static void payment(Connection conn, PaymentParams p) throws Exception {
        conn.setAutoCommit(false);
        try (Statement st = conn.createStatement()) {
            String amt = fmt2(p.amount);
            st.executeUpdate("UPDATE warehouse SET w_ytd = w_ytd + " + amt + " WHERE w_id=" + p.wId);
            try (ResultSet rs = st.executeQuery(
                    "SELECT w_name, w_street, w_city, w_state, w_zip FROM warehouse WHERE w_id=" + p.wId)) {
                while (rs.next()) { rs.getString("w_name"); }
            }
            st.executeUpdate("UPDATE district SET d_ytd = d_ytd + " + amt +
                    " WHERE d_w_id=" + p.wId + " AND d_id=" + p.dId);
            try (ResultSet rs = st.executeQuery(
                    "SELECT d_name, d_street, d_city, d_state, d_zip FROM district " +
                    "WHERE d_w_id=" + p.wId + " AND d_id=" + p.dId)) {
                while (rs.next()) { rs.getString("d_name"); }
            }
            try (ResultSet rs = st.executeQuery(
                    "SELECT c_first, c_middle, c_last, c_balance, c_credit FROM customer " +
                    "WHERE c_w_id=" + p.wId + " AND c_d_id=" + p.dId + " AND c_id=" + p.cId)) {
                while (rs.next()) { rs.getString("c_last"); }
            }
            st.executeUpdate("UPDATE customer SET c_balance = c_balance - " + amt +
                    ", c_ytd_payment = c_ytd_payment + " + amt +
                    ", c_payment_cnt = c_payment_cnt + 1" +
                    " WHERE c_w_id=" + p.wId + " AND c_d_id=" + p.dId + " AND c_id=" + p.cId);
            st.executeUpdate(
                "INSERT INTO history (h_c_id, h_c_d_id, h_c_w_id, h_d_id, h_w_id, h_date, h_amount, h_data) " +
                "VALUES (" + p.cId + ", " + p.dId + ", " + p.wId + ", " + p.dId + ", " + p.wId + ", NOW(), " + amt + ", 'BENCH')");
            conn.commit();
        } catch (Exception e) {
            conn.rollback();
            throw e;
        }
    }

    public static void orderStatus(Connection conn, OrderStatusParams p) throws Exception {
        conn.setAutoCommit(false);
        try (Statement st = conn.createStatement()) {
            try (ResultSet rs = st.executeQuery(
                    "SELECT c_first, c_middle, c_last, c_balance FROM customer " +
                    "WHERE c_w_id=" + p.wId + " AND c_d_id=" + p.dId + " AND c_id=" + p.cId)) {
                while (rs.next()) { rs.getString("c_last"); }
            }
            int oId = -1;
            try (ResultSet rs = st.executeQuery(
                    "SELECT o_id, o_entry_d, o_carrier_id FROM orders " +
                    "WHERE o_w_id=" + p.wId + " AND o_d_id=" + p.dId + " AND o_c_id=" + p.cId +
                    " ORDER BY o_id DESC LIMIT 1")) {
                if (rs.next()) oId = rs.getInt("o_id");
            }
            if (oId == -1) { conn.commit(); return; }
            try (ResultSet rs = st.executeQuery(
                    "SELECT ol_i_id, ol_supply_w_id, ol_quantity, ol_amount, ol_delivery_d " +
                    "FROM order_line WHERE ol_w_id=" + p.wId + " AND ol_d_id=" + p.dId + " AND ol_o_id=" + oId)) {
                while (rs.next()) { rs.getInt("ol_i_id"); }
            }
            conn.commit();
        } catch (Exception e) {
            conn.rollback();
            throw e;
        }
    }

    public static void delivery(Connection conn, DeliveryParams p) throws Exception {
        conn.setAutoCommit(false);
        try (Statement st = conn.createStatement()) {
            for (int dId = 1; dId <= 10; dId++) {
                int oId;
                try (ResultSet rs = st.executeQuery(
                        "SELECT no_o_id FROM new_order " +
                        "WHERE no_w_id=" + p.wId + " AND no_d_id=" + dId +
                        " ORDER BY no_o_id ASC LIMIT 1")) {
                    if (!rs.next()) continue;
                    oId = rs.getInt("no_o_id");
                }
                st.executeUpdate("DELETE FROM new_order " +
                        "WHERE no_w_id=" + p.wId + " AND no_d_id=" + dId + " AND no_o_id=" + oId);
                int cId;
                try (ResultSet rs = st.executeQuery(
                        "SELECT o_c_id FROM orders " +
                        "WHERE o_w_id=" + p.wId + " AND o_d_id=" + dId + " AND o_id=" + oId)) {
                    rs.next();
                    cId = rs.getInt("o_c_id");
                }
                st.executeUpdate("UPDATE orders SET o_carrier_id=" + p.carrierId +
                        " WHERE o_w_id=" + p.wId + " AND o_d_id=" + dId + " AND o_id=" + oId);
                st.executeUpdate("UPDATE order_line SET ol_delivery_d=NOW()" +
                        " WHERE ol_w_id=" + p.wId + " AND ol_d_id=" + dId + " AND ol_o_id=" + oId);
                double amount;
                try (ResultSet rs = st.executeQuery(
                        "SELECT COALESCE(SUM(ol_amount), 0) AS total FROM order_line " +
                        "WHERE ol_w_id=" + p.wId + " AND ol_d_id=" + dId + " AND ol_o_id=" + oId)) {
                    rs.next();
                    amount = rs.getDouble("total");
                }
                st.executeUpdate("UPDATE customer SET c_balance = c_balance + " + fmt2(amount) +
                        ", c_delivery_cnt = c_delivery_cnt + 1" +
                        " WHERE c_w_id=" + p.wId + " AND c_d_id=" + dId + " AND c_id=" + cId);
            }
            conn.commit();
        } catch (Exception e) {
            conn.rollback();
            throw e;
        }
    }

    public static void stockLevel(Connection conn, StockLevelParams p) throws Exception {
        conn.setAutoCommit(false);
        try (Statement st = conn.createStatement()) {
            int nextOId;
            try (ResultSet rs = st.executeQuery(
                    "SELECT d_next_o_id FROM district WHERE d_w_id=" + p.wId + " AND d_id=" + p.dId)) {
                rs.next();
                nextOId = rs.getInt("d_next_o_id");
            }
            int lowOId = nextOId - 20;
            try (ResultSet rs = st.executeQuery(
                    "SELECT COUNT(DISTINCT s.s_i_id) AS low_stock FROM order_line ol " +
                    "JOIN stock s ON s.s_w_id=ol.ol_w_id AND s.s_i_id=ol.ol_i_id " +
                    "WHERE ol.ol_w_id=" + p.wId + " AND ol.ol_d_id=" + p.dId +
                    "  AND ol.ol_o_id >= " + lowOId + " AND ol.ol_o_id < " + nextOId +
                    "  AND s.s_quantity < " + p.threshold)) {
                rs.next();
                rs.getInt("low_stock");
            }
            conn.commit();
        } catch (Exception e) {
            conn.rollback();
            throw e;
        }
    }
}
