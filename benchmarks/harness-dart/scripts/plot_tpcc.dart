/// Generates SVG plots from the TPC-C benchmark CSV.
///
/// Output:
///   ../docker/bench/outputs/legacy/tpcc-baseline.svg     (latency p50/p95/p99 grouped bars)
///   ../docker/bench/outputs/legacy/tpcc-baseline-rss.svg (RSS over tx_count)
///
/// SVG instead of PNG so we don't depend on Python+matplotlib
/// (incompatible Mach-O architecture on this Mac). SVG is academically
/// reproducible, vector, lossless, web-friendly.
///
/// Run from `benchmarks/`:
///   dart run scripts/plot_tpcc.dart
library;

import 'dart:io';

const _csvPath = '../docker/bench/outputs/legacy/tpcc-baseline.csv';
const _rssPath = '../docker/bench/outputs/legacy/tpcc-baseline-rss.csv';
const _svgPath = '../docker/bench/outputs/legacy/tpcc-baseline.svg';
const _rssSvgPath = '../docker/bench/outputs/legacy/tpcc-baseline-rss.svg';

const _txTypes = [
  'newOrder',
  'payment',
  'orderStatus',
  'delivery',
  'stockLevel'
];
const _drivers = ['native', 'postgres'];

const _nativeColor = '#1e88e5'; // blue
const _postgresColor = '#fb8c00'; // orange

void main() {
  final samples = _loadSamples(_csvPath);
  final rssSamples = _loadRssSamples(_rssPath);

  // Group by (driver, tx_type) → list of latency_us.
  final grouped = <String, Map<String, List<int>>>{
    for (final d in _drivers) d: {for (final t in _txTypes) t: <int>[]},
  };
  for (final s in samples) {
    if (!s.success) continue;
    grouped[s.driver]?[s.txType]?.add(s.latencyUs);
  }

  // Compute p50/p95/p99 per (driver, tx_type).
  final stats = <String, Map<String, _Stats>>{
    for (final d in _drivers) d: {},
  };
  for (final d in _drivers) {
    for (final t in _txTypes) {
      final lats = grouped[d]![t]!;
      stats[d]![t] = _Stats.fromLatencies(lats);
    }
  }

  // Emit grouped-bar SVG.
  final svg = _renderLatencySvg(stats);
  File(_svgPath).writeAsStringSync(svg);
  print('[plot] wrote $_svgPath');

  // Emit RSS time-series SVG.
  final rssSvg = _renderRssSvg(rssSamples);
  File(_rssSvgPath).writeAsStringSync(rssSvg);
  print('[plot] wrote $_rssSvgPath');

  // Print summary.
  print('\n=== Latency summary (microseconds) ===');
  for (final t in _txTypes) {
    final n = stats['native']![t]!;
    final p = stats['postgres']![t]!;
    print('$t:');
    print('  native   p50=${n.p50} p95=${n.p95} p99=${n.p99} (n=${n.count})');
    print('  postgres p50=${p.p50} p95=${p.p95} p99=${p.p99} (n=${p.count})');
    print('  native advantage: p50=${_pct(n.p50, p.p50)} '
        'p95=${_pct(n.p95, p.p95)} p99=${_pct(n.p99, p.p99)}');
  }
}

String _pct(int n, int p) {
  if (p == 0) return '—';
  final diff = (p - n) * 100.0 / p;
  return '${diff.toStringAsFixed(1)}% faster';
}

class _TpccSample {
  final int runId;
  final String driver;
  final String txType;
  final int latencyUs;
  final bool success;
  _TpccSample(this.runId, this.driver, this.txType, this.latencyUs, this.success);
}

class _RssSample {
  final int runId;
  final String driver;
  final int txCount;
  final int rssBytes;
  _RssSample(this.runId, this.driver, this.txCount, this.rssBytes);
}

List<_TpccSample> _loadSamples(String path) {
  final lines = File(path).readAsLinesSync();
  return lines.skip(1).where((l) => l.isNotEmpty).map((l) {
    final p = l.split(',');
    return _TpccSample(
      int.parse(p[0]),
      p[1],
      p[2],
      int.parse(p[3]),
      p[4] == '1',
    );
  }).toList();
}

List<_RssSample> _loadRssSamples(String path) {
  final lines = File(path).readAsLinesSync();
  return lines.skip(1).where((l) => l.isNotEmpty).map((l) {
    final p = l.split(',');
    return _RssSample(
      int.parse(p[0]),
      p[1],
      int.parse(p[2]),
      int.parse(p[3]),
    );
  }).toList();
}

class _Stats {
  final int count;
  final int p50;
  final int p95;
  final int p99;
  final int max;
  _Stats(this.count, this.p50, this.p95, this.p99, this.max);

  factory _Stats.fromLatencies(List<int> raw) {
    if (raw.isEmpty) return _Stats(0, 0, 0, 0, 0);
    final lats = List.of(raw)..sort();
    int at(double f) => lats[(f * (lats.length - 1)).round()];
    return _Stats(lats.length, at(0.5), at(0.95), at(0.99), lats.last);
  }
}

String _renderLatencySvg(Map<String, Map<String, _Stats>> stats) {
  // Layout: 5 tx types horizontally; for each, 3 percentile groups
  // (p50/p95/p99); within each group, 2 bars (native, postgres).
  const w = 1200;
  const h = 600;
  const margin = 60;
  const groupGap = 40;
  const barGap = 4;
  const barWidth = 22;
  final txWidth = (w - 2 * margin - groupGap * (_txTypes.length - 1)) / _txTypes.length;

  // Max latency for y-scale across all p99 (chart top).
  var maxY = 0;
  for (final d in _drivers) {
    for (final t in _txTypes) {
      maxY = maxY < stats[d]![t]!.p99 ? stats[d]![t]!.p99 : maxY;
    }
  }
  // Round up to next 1000.
  maxY = ((maxY ~/ 1000) + 1) * 1000;

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="12">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="24" text-anchor="middle" font-size="18" font-weight="bold">TPC-C latency — dart_db_connector vs postgres package</text>');
  svg.writeln(
      '<text x="${w / 2}" y="44" text-anchor="middle" font-size="11" fill="#555">3W/30D/9kC seed · 3 reps × 5000 tx · mix 45/43/4/4/4 · Docker Postgres on macOS arm64</text>');

  // Y-axis grid + labels.
  const gridLines = 5;
  final chartTop = 80.0;
  final chartBottom = h - 90.0;
  final chartHeight = chartBottom - chartTop;
  for (var i = 0; i <= gridLines; i++) {
    final y = chartBottom - (i / gridLines) * chartHeight;
    final v = (i / gridLines * maxY).round();
    svg.writeln(
        '<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${(v / 1000).toStringAsFixed(1)}ms</text>');
  }
  svg.writeln('<text x="${margin - 40}" y="${chartTop - 10}" fill="#666">latency</text>');

  // Bars + group labels.
  for (var ti = 0; ti < _txTypes.length; ti++) {
    final t = _txTypes[ti];
    final groupX = margin + ti * (txWidth + groupGap);

    // 3 percentiles × 2 drivers = 6 bars per tx group.
    const percLabels = ['p50', 'p95', 'p99'];
    final percGetters = <int Function(_Stats)>[
      (s) => s.p50,
      (s) => s.p95,
      (s) => s.p99,
    ];
    for (var pi = 0; pi < 3; pi++) {
      final subGroupX = groupX +
          pi * (txWidth / 3) +
          (txWidth / 3 - (barWidth * 2 + barGap)) / 2;
      for (var di = 0; di < _drivers.length; di++) {
        final d = _drivers[di];
        final v = percGetters[pi](stats[d]![t]!);
        final barH = (v / maxY) * chartHeight;
        final barX = subGroupX + di * (barWidth + barGap);
        final barY = chartBottom - barH;
        final color = d == 'native' ? _nativeColor : _postgresColor;
        svg.writeln(
            '<rect x="$barX" y="$barY" width="$barWidth" height="$barH" fill="$color"/>');
        svg.writeln(
            '<text x="${barX + barWidth / 2}" y="${barY - 4}" text-anchor="middle" font-size="10" fill="#333">${(v / 1000).toStringAsFixed(1)}</text>');
      }
      svg.writeln(
          '<text x="${subGroupX + barWidth + barGap / 2}" y="${chartBottom + 16}" text-anchor="middle" fill="#666">${percLabels[pi]}</text>');
    }
    // Tx label
    svg.writeln(
        '<text x="${groupX + txWidth / 2}" y="${chartBottom + 38}" text-anchor="middle" font-weight="bold">$t</text>');
  }

  // Axis line.
  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');

  // Legend.
  final legendY = h - 30;
  svg.writeln(
      '<rect x="${w / 2 - 130}" y="${legendY - 12}" width="14" height="14" fill="$_nativeColor"/>');
  svg.writeln(
      '<text x="${w / 2 - 110}" y="$legendY">dart_db_connector (native)</text>');
  svg.writeln(
      '<rect x="${w / 2 + 30}" y="${legendY - 12}" width="14" height="14" fill="$_postgresColor"/>');
  svg.writeln(
      '<text x="${w / 2 + 50}" y="$legendY">postgres package (v3)</text>');

  svg.writeln('</svg>');
  return svg.toString();
}

String _renderRssSvg(List<_RssSample> rssSamples) {
  const w = 1200;
  const h = 400;
  const margin = 70;
  final chartTop = 60.0;
  final chartBottom = h - 60.0;
  final chartHeight = chartBottom - chartTop;
  final chartWidth = (w - 2 * margin).toDouble();

  // Max RSS for y-scale.
  final allRss = rssSamples.map((s) => s.rssBytes).toList();
  if (allRss.isEmpty) return '<svg></svg>';
  final maxRss = allRss.reduce((a, b) => a > b ? a : b);
  final maxMiB = (maxRss / 1024 / 1024).ceil();
  // Round up.
  final yMaxMiB = (maxMiB ~/ 50 + 1) * 50;

  // Group by driver.
  final native = rssSamples.where((s) => s.driver == 'native').toList();
  final postgres = rssSamples.where((s) => s.driver == 'postgres').toList();
  final maxTxCount = rssSamples
      .map((s) => (s.runId - 1) * 5000 + s.txCount)
      .fold<int>(0, (a, b) => a > b ? a : b);

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="12">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="24" text-anchor="middle" font-size="16" font-weight="bold">RSS over benchmark execution</text>');

  // Y grid + labels.
  for (var i = 0; i <= 5; i++) {
    final y = chartBottom - (i / 5) * chartHeight;
    final v = (i / 5 * yMaxMiB).round();
    svg.writeln(
        '<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${v}MiB</text>');
  }

  // X-axis label.
  svg.writeln(
      '<text x="${w / 2}" y="${h - 20}" text-anchor="middle" fill="#666">transactions completed (cumulative across reps)</text>');

  // Line plots.
  void plot(List<_RssSample> samples, String color) {
    if (samples.isEmpty) return;
    final pts = <String>[];
    for (final s in samples) {
      final cum = (s.runId - 1) * 5000 + s.txCount;
      final x = margin + (cum / maxTxCount) * chartWidth;
      final rssMiB = s.rssBytes / 1024 / 1024;
      final y = chartBottom - (rssMiB / yMaxMiB) * chartHeight;
      pts.add('${x.toStringAsFixed(1)},${y.toStringAsFixed(1)}');
    }
    svg.writeln(
        '<polyline fill="none" stroke="$color" stroke-width="1.5" points="${pts.join(' ')}"/>');
  }

  plot(native, _nativeColor);
  plot(postgres, _postgresColor);

  // Axis lines.
  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');
  svg.writeln(
      '<line x1="$margin" y1="$chartTop" x2="$margin" y2="$chartBottom" stroke="#333"/>');

  // Legend.
  final legendY = h - 50;
  svg.writeln(
      '<rect x="${w - 280}" y="${legendY - 12}" width="14" height="14" fill="$_nativeColor"/>');
  svg.writeln(
      '<text x="${w - 260}" y="$legendY">dart_db_connector</text>');
  svg.writeln(
      '<rect x="${w - 280}" y="${legendY + 8}" width="14" height="14" fill="$_postgresColor"/>');
  svg.writeln(
      '<text x="${w - 260}" y="${legendY + 20}">postgres package</text>');

  svg.writeln('</svg>');
  return svg.toString();
}
