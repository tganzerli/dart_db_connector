use rand::{Rng, SeedableRng};
use rand_chacha::ChaCha8Rng;

pub const K_WAREHOUSES: u32 = 3;
pub const K_DISTRICTS_PER_WAREHOUSE: u32 = 10;
pub const K_CUSTOMERS_PER_DISTRICT: u32 = 300;
pub const K_ITEMS: u32 = 100_000;

#[derive(Clone, Copy, Debug)]
pub enum TxType {
    NewOrder,
    Payment,
    OrderStatus,
    Delivery,
    StockLevel,
}

impl TxType {
    pub fn name(&self) -> &'static str {
        match self {
            TxType::NewOrder => "newOrder",
            TxType::Payment => "payment",
            TxType::OrderStatus => "orderStatus",
            TxType::Delivery => "delivery",
            TxType::StockLevel => "stockLevel",
        }
    }
}

#[derive(Debug)]
pub struct NewOrderLine {
    pub i_id: i32,
    pub supply_w_id: i32,
    pub quantity: i32,
}

#[derive(Debug)]
pub struct NewOrderParams {
    pub w_id: i32,
    pub d_id: i32,
    pub c_id: i32,
    pub lines: Vec<NewOrderLine>,
}

#[derive(Debug)]
pub struct PaymentParams {
    pub w_id: i32,
    pub d_id: i32,
    pub c_id: i32,
    pub amount: f64,
}

#[derive(Debug)]
pub struct OrderStatusParams {
    pub w_id: i32,
    pub d_id: i32,
    pub c_id: i32,
}

#[derive(Debug)]
pub struct DeliveryParams {
    pub w_id: i32,
    pub carrier_id: i32,
}

#[derive(Debug)]
pub struct StockLevelParams {
    pub w_id: i32,
    pub d_id: i32,
    pub threshold: i32,
}

pub struct TpccMix {
    rng: ChaCha8Rng,
}

impl TpccMix {
    pub fn new(seed: u64) -> Self {
        Self { rng: ChaCha8Rng::seed_from_u64(seed) }
    }

    pub fn next_type(&mut self) -> TxType {
        let r = self.rng.gen_range(0..100);
        if r < 45 { TxType::NewOrder }
        else if r < 88 { TxType::Payment }
        else if r < 92 { TxType::OrderStatus }
        else if r < 96 { TxType::Delivery }
        else { TxType::StockLevel }
    }

    fn w(&mut self) -> i32 { 1 + self.rng.gen_range(0..K_WAREHOUSES) as i32 }
    fn d(&mut self) -> i32 { 1 + self.rng.gen_range(0..K_DISTRICTS_PER_WAREHOUSE) as i32 }
    fn c(&mut self) -> i32 { 1 + self.rng.gen_range(0..K_CUSTOMERS_PER_DISTRICT) as i32 }
    fn item(&mut self) -> i32 { 1 + self.rng.gen_range(0..K_ITEMS) as i32 }

    pub fn new_order(&mut self) -> NewOrderParams {
        let w_id = self.w();
        let ol_cnt = 5 + self.rng.gen_range(0..11) as usize;
        let d_id = self.d();
        let c_id = self.c();
        let mut lines = Vec::with_capacity(ol_cnt);
        for _ in 0..ol_cnt {
            let remote = self.rng.gen_range(0..100) == 0;
            let supply_w_id = if remote {
                1 + self.rng.gen_range(0..K_WAREHOUSES) as i32
            } else {
                w_id
            };
            lines.push(NewOrderLine {
                i_id: self.item(),
                supply_w_id,
                quantity: 1 + self.rng.gen_range(0..10) as i32,
            });
        }
        NewOrderParams { w_id, d_id, c_id, lines }
    }

    pub fn payment(&mut self) -> PaymentParams {
        let w_id = self.w();
        let d_id = self.d();
        let c_id = self.c();
        let amount = 1.0 + self.rng.gen_range(0..5000) as f64 + self.rng.gen::<f64>();
        let amount = (amount * 100.0).round() / 100.0;
        PaymentParams { w_id, d_id, c_id, amount }
    }

    pub fn order_status(&mut self) -> OrderStatusParams {
        OrderStatusParams { w_id: self.w(), d_id: self.d(), c_id: self.c() }
    }

    pub fn delivery(&mut self) -> DeliveryParams {
        DeliveryParams { w_id: self.w(), carrier_id: 1 + self.rng.gen_range(0..10) as i32 }
    }

    pub fn stock_level(&mut self) -> StockLevelParams {
        StockLevelParams { w_id: self.w(), d_id: self.d(), threshold: 10 + self.rng.gen_range(0..11) as i32 }
    }
}
