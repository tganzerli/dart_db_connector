/// Smoke test for NativeTpccDriver — runs one of each transaction
/// type and prints OK on each. Use to validate Phase B native before
/// implementing the postgres-package side.
library;

import 'transactions_native.dart';
import 'tpcc_driver.dart';

Future<void> main() async {
  final driver = NativeTpccDriver(poolSize: 2);
  await driver.setup();

  print('[smoke] newOrder...');
  await driver.newOrder(NewOrderParams(1, 1, 1, [
    const NewOrderLineItem(1, 1, 3),
    const NewOrderLineItem(2, 1, 1),
    const NewOrderLineItem(3, 1, 5),
  ]));
  print('[ok] newOrder');

  print('[smoke] payment...');
  await driver.payment(const PaymentParams(1, 1, 1, 123.45));
  print('[ok] payment');

  print('[smoke] orderStatus...');
  await driver.orderStatus(const OrderStatusParams(1, 1, 1));
  print('[ok] orderStatus');

  print('[smoke] delivery...');
  await driver.delivery(const DeliveryParams(1, 5));
  print('[ok] delivery');

  print('[smoke] stockLevel...');
  await driver.stockLevel(const StockLevelParams(1, 1, 15));
  print('[ok] stockLevel');

  await driver.close();
  print('[done] all 5 transactions smoke-passed');
}
