package main

import "math/rand"

const (
	kWarehouses            = 3
	kDistrictsPerWarehouse = 10
	kCustomersPerDistrict  = 300
	kItems                 = 100000
)

type TxType int

const (
	TxNewOrder TxType = iota
	TxPayment
	TxOrderStatus
	TxDelivery
	TxStockLevel
)

func (t TxType) Name() string {
	switch t {
	case TxNewOrder:
		return "newOrder"
	case TxPayment:
		return "payment"
	case TxOrderStatus:
		return "orderStatus"
	case TxDelivery:
		return "delivery"
	case TxStockLevel:
		return "stockLevel"
	}
	return "unknown"
}

type NewOrderLine struct {
	IID       int
	SupplyWID int
	Quantity  int
}

type NewOrderParams struct {
	WID, DID, CID int
	Lines         []NewOrderLine
}

type PaymentParams struct {
	WID, DID, CID int
	Amount        float64
}

type OrderStatusParams struct{ WID, DID, CID int }
type DeliveryParams struct{ WID, CarrierID int }
type StockLevelParams struct{ WID, DID, Threshold int }

// TpccMix mirrors `benchmarks/scripts/tpcc/mix.dart`.
type TpccMix struct {
	rng *rand.Rand
}

func NewTpccMix(seed int64) *TpccMix {
	return &TpccMix{rng: rand.New(rand.NewSource(seed))}
}

func (m *TpccMix) NextType() TxType {
	r := m.rng.Intn(100)
	switch {
	case r < 45:
		return TxNewOrder
	case r < 88:
		return TxPayment
	case r < 92:
		return TxOrderStatus
	case r < 96:
		return TxDelivery
	default:
		return TxStockLevel
	}
}

func (m *TpccMix) w() int    { return 1 + m.rng.Intn(kWarehouses) }
func (m *TpccMix) d() int    { return 1 + m.rng.Intn(kDistrictsPerWarehouse) }
func (m *TpccMix) c() int    { return 1 + m.rng.Intn(kCustomersPerDistrict) }
func (m *TpccMix) item() int { return 1 + m.rng.Intn(kItems) }

func (m *TpccMix) NewOrder() NewOrderParams {
	wID := m.w()
	olCnt := 5 + m.rng.Intn(11)
	lines := make([]NewOrderLine, 0, olCnt)
	for i := 0; i < olCnt; i++ {
		remote := m.rng.Intn(100) == 0
		supply := wID
		if remote {
			supply = 1 + m.rng.Intn(kWarehouses)
		}
		lines = append(lines, NewOrderLine{
			IID:       m.item(),
			SupplyWID: supply,
			Quantity:  1 + m.rng.Intn(10),
		})
	}
	return NewOrderParams{WID: wID, DID: m.d(), CID: m.c(), Lines: lines}
}

func (m *TpccMix) Payment() PaymentParams {
	wID := m.w()
	amount := 1.0 + float64(m.rng.Intn(5000)) + m.rng.Float64()
	// Round to 2 decimals (parity with Dart `toStringAsFixed(2)`).
	amount = float64(int64(amount*100+0.5)) / 100.0
	return PaymentParams{WID: wID, DID: m.d(), CID: m.c(), Amount: amount}
}

func (m *TpccMix) OrderStatus() OrderStatusParams {
	return OrderStatusParams{WID: m.w(), DID: m.d(), CID: m.c()}
}

func (m *TpccMix) Delivery() DeliveryParams {
	return DeliveryParams{WID: m.w(), CarrierID: 1 + m.rng.Intn(10)}
}

func (m *TpccMix) StockLevel() StockLevelParams {
	return StockLevelParams{WID: m.w(), DID: m.d(), Threshold: 10 + m.rng.Intn(11)}
}
