import seedrandom from 'seedrandom';

export const kWarehouses = 3;
export const kDistrictsPerWarehouse = 10;
export const kCustomersPerDistrict = 300;
export const kItems = 100000;

export const TxType = Object.freeze({
  newOrder: 'newOrder',
  payment: 'payment',
  orderStatus: 'orderStatus',
  delivery: 'delivery',
  stockLevel: 'stockLevel',
});

export class TpccMix {
  constructor(seed) {
    this._rng = seedrandom(String(seed));
  }
  _nextInt(n) {
    return Math.floor(this._rng() * n);
  }
  _nextDouble() {
    return this._rng();
  }
  nextType() {
    const r = this._nextInt(100);
    if (r < 45) return TxType.newOrder;
    if (r < 88) return TxType.payment;
    if (r < 92) return TxType.orderStatus;
    if (r < 96) return TxType.delivery;
    return TxType.stockLevel;
  }
  _w() { return 1 + this._nextInt(kWarehouses); }
  _d() { return 1 + this._nextInt(kDistrictsPerWarehouse); }
  _c() { return 1 + this._nextInt(kCustomersPerDistrict); }
  _item() { return 1 + this._nextInt(kItems); }

  newOrder() {
    const wId = this._w();
    const dId = this._d();
    const cId = this._c();
    const olCnt = 5 + this._nextInt(11);
    const lines = [];
    for (let i = 0; i < olCnt; i++) {
      const remote = this._nextInt(100) === 0;
      const supplyWId = remote ? 1 + this._nextInt(kWarehouses) : wId;
      lines.push({
        iId: this._item(),
        supplyWId,
        quantity: 1 + this._nextInt(10),
      });
    }
    return { wId, dId, cId, lines };
  }

  payment() {
    const wId = this._w();
    const amountRaw = 1.0 + this._nextInt(5000) + this._nextDouble();
    const amount = Math.round(amountRaw * 100) / 100;
    return { wId, dId: this._d(), cId: this._c(), amount };
  }

  orderStatus() {
    return { wId: this._w(), dId: this._d(), cId: this._c() };
  }

  delivery() {
    return { wId: this._w(), carrierId: 1 + this._nextInt(10) };
  }

  stockLevel() {
    return { wId: this._w(), dId: this._d(), threshold: 10 + this._nextInt(11) };
  }
}
