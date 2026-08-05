/// TPC-C transaction mix + parameter generation with seeded RNG.
library;

import 'dart:io';
import 'dart:math';

import 'tpcc_driver.dart';

/// Configurable via `TPCC_WAREHOUSES` env (default 3). Used by both the
/// seed and the workload generator — MUST match in any given session.
/// .2.a (2026-05-20) added the env knob to test the row-contention
/// mitigation hypothesis: low warehouse count concentrates updates on
/// ~30 hot rows; higher counts dilute the lock queue.
final int kWarehouses =
    int.tryParse(Platform.environment['TPCC_WAREHOUSES'] ?? '') ?? 3;
const int kDistrictsPerWarehouse = 10;
const int kCustomersPerDistrict = 300;
const int kItems = 100000;

enum TxType { newOrder, payment, orderStatus, delivery, stockLevel }

/// Canonical TPC-C mix (45/43/4/4/4). Cumulative weights × 100.
const _newOrderCum = 45;
const _paymentCum = 88; // 45 + 43
const _orderStatusCum = 92;
const _deliveryCum = 96;
// stockLevel covers the remaining 4 → cum 100.

class TpccMix {
  final Random _rng;

  TpccMix(int seed) : _rng = Random(seed);

  /// Picks the next transaction type respecting the mix percentages.
  TxType nextType() {
    final r = _rng.nextInt(100);
    if (r < _newOrderCum) return TxType.newOrder;
    if (r < _paymentCum) return TxType.payment;
    if (r < _orderStatusCum) return TxType.orderStatus;
    if (r < _deliveryCum) return TxType.delivery;
    return TxType.stockLevel;
  }

  int _w() => 1 + _rng.nextInt(kWarehouses);
  int _d() => 1 + _rng.nextInt(kDistrictsPerWarehouse);
  int _c() => 1 + _rng.nextInt(kCustomersPerDistrict);
  int _item() => 1 + _rng.nextInt(kItems);

  NewOrderParams newOrderParams() {
    final wId = _w();
    final dId = _d();
    final cId = _c();
    final olCnt = 5 + _rng.nextInt(11); // 5..15 per spec
    final lines = <NewOrderLineItem>[];
    for (var i = 0; i < olCnt; i++) {
      // 1% supply remote (spec). For our 3W setup keep simple: 99% local.
      final remote = _rng.nextInt(100) == 0;
      final supplyWId = remote
          ? 1 + _rng.nextInt(kWarehouses)
          : wId;
      final iId = _item();
      final qty = 1 + _rng.nextInt(10);
      lines.add(NewOrderLineItem(iId, supplyWId, qty));
    }
    return NewOrderParams(wId, dId, cId, lines);
  }

  PaymentParams paymentParams() {
    final wId = _w();
    final dId = _d();
    final cId = _c();
    final amount = 1.0 + _rng.nextInt(5000) + _rng.nextDouble();
    return PaymentParams(wId, dId, cId, double.parse(amount.toStringAsFixed(2)));
  }

  OrderStatusParams orderStatusParams() =>
      OrderStatusParams(_w(), _d(), _c());

  DeliveryParams deliveryParams() => DeliveryParams(_w(), 1 + _rng.nextInt(10));

  StockLevelParams stockLevelParams() =>
      StockLevelParams(_w(), _d(), 10 + _rng.nextInt(11));
}
