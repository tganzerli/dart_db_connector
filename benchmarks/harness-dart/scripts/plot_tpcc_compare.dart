/// Generates comparative SVG plots showing single-isolate vs multi-isolate
/// for both drivers (4 series per tx_type).
///
/// Reads:
///   ../docker/bench/outputs/legacy/tpcc-baseline.csv        (single)
///   ../docker/bench/outputs/legacy/tpcc-multi-isolate.csv   (multi)
///
/// Writes:
///   ../docker/bench/outputs/legacy/tpcc-multi-isolate.svg
library;

import 'dart:io';

const _singleCsv = '../docker/bench/outputs/legacy/tpcc-baseline.csv';
const _multiCsv = '../docker/bench/outputs/legacy/tpcc-multi-isolate.csv';
const _outSvg = '../docker/bench/outputs/legacy/tpcc-multi-isolate.svg';

const _txTypes = [
  'newOrder',
  'payment',
  'orderStatus',
  'delivery',
  'stockLevel'
];

class _Series {
  final String label;
  final String color;
  _Series(this.label, this.color);
}

final _series = <_Series>[
  _Series('native single', '#1e88e5'),
  _Series('native multi', '#0d47a1'),
  _Series('postgres single', '#fb8c00'),
  _Series('postgres multi', '#e65100'),
];

void main() {
  final single = _loadSamples(_singleCsv);
  final multi = _loadSamples(_multiCsv);

  // Compute p99 per (label, tx_type).
  Map<String, Map<String, _Stats>> stats = {
    'native single': _statsByTx(single.where((s) => s.driver == 'native')),
    'postgres single': _statsByTx(single.where((s) => s.driver == 'postgres')),
    'native multi': _statsByTx(multi.where((s) => s.driver == 'native')),
    'postgres multi': _statsByTx(multi.where((s) => s.driver == 'postgres')),
  };

  // Render two charts side-by-side in one SVG: (a) p95 grouped bars,
  // (b) p99 grouped bars.
  final svg = _render(stats);
  File(_outSvg).writeAsStringSync(svg);
  print('[plot] wrote $_outSvg');

  // Summary table to stdout.
  print('\n=== p99 latency (µs) ===');
  print('tx           | nat-s   | nat-m   | pg-s    | pg-m    | nat advantage (single → multi)');
  for (final t in _txTypes) {
    final ns = stats['native single']![t]!.p99;
    final nm = stats['native multi']![t]!.p99;
    final ps = stats['postgres single']![t]!.p99;
    final pm = stats['postgres multi']![t]!.p99;
    final singleAdv = (100.0 * (ps - ns) / ps).toStringAsFixed(1);
    final multiAdv = (100.0 * (pm - nm) / pm).toStringAsFixed(1);
    print(_pad(t, 12) +
        ' | ${_pad('$ns', 7)} | ${_pad('$nm', 7)} | ${_pad('$ps', 7)} | ${_pad('$pm', 7)} | ${_pad('$singleAdv% → $multiAdv%', 14)}');
  }
}

String _pad(String s, int n) => s.padRight(n);

class _Sample {
  final String driver;
  final String txType;
  final int latencyUs;
  final bool success;
  _Sample(this.driver, this.txType, this.latencyUs, this.success);
}

class _Stats {
  final int p50;
  final int p95;
  final int p99;
  final int count;
  _Stats(this.p50, this.p95, this.p99, this.count);
}

List<_Sample> _loadSamples(String path) {
  final lines = File(path).readAsLinesSync();
  return lines.skip(1).where((l) => l.isNotEmpty).map((l) {
    final p = l.split(',');
    return _Sample(p[1], p[2], int.parse(p[3]), p[4] == '1');
  }).toList();
}

Map<String, _Stats> _statsByTx(Iterable<_Sample> samples) {
  final byTx = <String, List<int>>{};
  for (final s in samples) {
    if (!s.success) continue;
    byTx.putIfAbsent(s.txType, () => []).add(s.latencyUs);
  }
  final out = <String, _Stats>{};
  for (final t in _txTypes) {
    final lats = (byTx[t] ?? const <int>[])..sort();
    if (lats.isEmpty) {
      out[t] = _Stats(0, 0, 0, 0);
    } else {
      int at(double f) => lats[(f * (lats.length - 1)).round()];
      out[t] = _Stats(at(0.5), at(0.95), at(0.99), lats.length);
    }
  }
  return out;
}

String _render(Map<String, Map<String, _Stats>> stats) {
  const w = 1400;
  const h = 700;
  const margin = 70;
  const txGap = 50;
  const seriesWidth = 18;
  const seriesGap = 2;
  final groupW = 4 * (seriesWidth + seriesGap);
  final chartW = (w - 2 * margin - txGap * (_txTypes.length - 1)).toDouble();
  final txW = chartW / _txTypes.length;

  // Use p99 as the chart metric (most discriminative).
  var maxY = 0;
  for (final s in _series.map((x) => x.label)) {
    for (final t in _txTypes) {
      final v = stats[s]![t]!.p99;
      if (v > maxY) maxY = v;
    }
  }
  // round up to next 5000.
  maxY = ((maxY ~/ 5000) + 1) * 5000;

  final chartTop = 110.0;
  final chartBottom = h - 130.0;
  final chartHeight = chartBottom - chartTop;

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="12">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="30" text-anchor="middle" font-size="20" font-weight="bold">TPC-C p99 latency — single-isolate vs multi-isolate (4 workers × 4 conns)</text>');
  svg.writeln(
      '<text x="${w / 2}" y="55" text-anchor="middle" font-size="12" fill="#555">dart_db_connector vs postgres package · 3 reps × 5000 tx · mix 45/43/4/4/4</text>');
  svg.writeln(
      '<text x="${w / 2}" y="76" text-anchor="middle" font-size="11" fill="#777">Multi-isolate doubles TPS for both drivers, but the single-isolate native advantage (+12%) collapses to +1% — server-side contention dominates.</text>');

  // Y grid + labels (in milliseconds).
  for (var i = 0; i <= 5; i++) {
    final y = chartBottom - (i / 5) * chartHeight;
    final v = (i / 5 * maxY).round();
    svg.writeln(
        '<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${(v / 1000).toStringAsFixed(0)}ms</text>');
  }

  for (var ti = 0; ti < _txTypes.length; ti++) {
    final t = _txTypes[ti];
    final groupX = margin + ti * (txW + txGap);
    final centerOffset = (txW - groupW) / 2;
    for (var si = 0; si < _series.length; si++) {
      final s = _series[si];
      final v = stats[s.label]![t]!.p99;
      final barH = (v / maxY) * chartHeight;
      final barX = groupX + centerOffset + si * (seriesWidth + seriesGap);
      final barY = chartBottom - barH;
      svg.writeln(
          '<rect x="$barX" y="$barY" width="$seriesWidth" height="$barH" fill="${s.color}"/>');
      svg.writeln(
          '<text x="${barX + seriesWidth / 2}" y="${barY - 4}" text-anchor="middle" font-size="9" fill="#333">${(v / 1000).toStringAsFixed(1)}</text>');
    }
    svg.writeln(
        '<text x="${groupX + txW / 2}" y="${chartBottom + 20}" text-anchor="middle" font-weight="bold">$t</text>');
  }

  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');

  // Legend (horizontal).
  final legY = h - 50;
  final legX0 = (w - 4 * 200) / 2;
  for (var i = 0; i < _series.length; i++) {
    final s = _series[i];
    final lx = legX0 + i * 200;
    svg.writeln(
        '<rect x="$lx" y="${legY - 11}" width="14" height="14" fill="${s.color}"/>');
    svg.writeln('<text x="${lx + 20}" y="$legY">${s.label}</text>');
  }

  svg.writeln('</svg>');
  return svg.toString();
}
