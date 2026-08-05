package io.github.tganzerli.bench;

import java.util.ArrayList;
import java.util.List;
import java.util.Random;

public class Mix {
    public static final int K_WAREHOUSES = 3;
    public static final int K_DISTRICTS = 10;
    public static final int K_CUSTOMERS = 300;
    public static final int K_ITEMS = 100_000;

    public enum TxType {
        NEW_ORDER("newOrder"),
        PAYMENT("payment"),
        ORDER_STATUS("orderStatus"),
        DELIVERY("delivery"),
        STOCK_LEVEL("stockLevel");
        public final String name;
        TxType(String n) { this.name = n; }
    }

    public static class NewOrderLine {
        public final int iId;
        public final int supplyWId;
        public final int quantity;
        public NewOrderLine(int iId, int supplyWId, int quantity) {
            this.iId = iId; this.supplyWId = supplyWId; this.quantity = quantity;
        }
    }
    public static class NewOrderParams {
        public final int wId, dId, cId;
        public final List<NewOrderLine> lines;
        public NewOrderParams(int wId, int dId, int cId, List<NewOrderLine> lines) {
            this.wId = wId; this.dId = dId; this.cId = cId; this.lines = lines;
        }
    }
    public static class PaymentParams {
        public final int wId, dId, cId;
        public final double amount;
        public PaymentParams(int wId, int dId, int cId, double amount) {
            this.wId = wId; this.dId = dId; this.cId = cId; this.amount = amount;
        }
    }
    public static class OrderStatusParams {
        public final int wId, dId, cId;
        public OrderStatusParams(int wId, int dId, int cId) { this.wId = wId; this.dId = dId; this.cId = cId; }
    }
    public static class DeliveryParams {
        public final int wId, carrierId;
        public DeliveryParams(int wId, int carrierId) { this.wId = wId; this.carrierId = carrierId; }
    }
    public static class StockLevelParams {
        public final int wId, dId, threshold;
        public StockLevelParams(int wId, int dId, int threshold) { this.wId = wId; this.dId = dId; this.threshold = threshold; }
    }

    private final Random rng;
    public Mix(long seed) { this.rng = new Random(seed); }

    public TxType nextType() {
        int r = rng.nextInt(100);
        if (r < 45) return TxType.NEW_ORDER;
        if (r < 88) return TxType.PAYMENT;
        if (r < 92) return TxType.ORDER_STATUS;
        if (r < 96) return TxType.DELIVERY;
        return TxType.STOCK_LEVEL;
    }

    private int w() { return 1 + rng.nextInt(K_WAREHOUSES); }
    private int d() { return 1 + rng.nextInt(K_DISTRICTS); }
    private int c() { return 1 + rng.nextInt(K_CUSTOMERS); }
    private int item() { return 1 + rng.nextInt(K_ITEMS); }

    public NewOrderParams newOrder() {
        int wId = w();
        int olCnt = 5 + rng.nextInt(11);
        int dId = d();
        int cId = c();
        List<NewOrderLine> lines = new ArrayList<>(olCnt);
        for (int i = 0; i < olCnt; i++) {
            boolean remote = rng.nextInt(100) == 0;
            int supply = remote ? 1 + rng.nextInt(K_WAREHOUSES) : wId;
            lines.add(new NewOrderLine(item(), supply, 1 + rng.nextInt(10)));
        }
        return new NewOrderParams(wId, dId, cId, lines);
    }

    public PaymentParams payment() {
        int wId = w();
        int dId = d();
        int cId = c();
        double amount = 1.0 + rng.nextInt(5000) + rng.nextDouble();
        amount = Math.round(amount * 100.0) / 100.0;
        return new PaymentParams(wId, dId, cId, amount);
    }

    public OrderStatusParams orderStatus() { return new OrderStatusParams(w(), d(), c()); }
    public DeliveryParams delivery() { return new DeliveryParams(w(), 1 + rng.nextInt(10)); }
    public StockLevelParams stockLevel() { return new StockLevelParams(w(), d(), 10 + rng.nextInt(11)); }
}
