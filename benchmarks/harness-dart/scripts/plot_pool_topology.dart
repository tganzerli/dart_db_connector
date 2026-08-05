/// Plot sweep de topologias N×M (TPS + p99 NewOrder).
///
/// Lê: ../docker/bench/outputs/legacy/pool-topology.csv
/// Escreve:
///   ../docker/bench/outputs/legacy/pool-topology-tps.svg
///   ../docker/bench/outputs/legacy/pool-topology-p99.svg
library;

import 'dart:io';

const _csvPath = '../docker/bench/outputs/legacy/pool-topology.csv';
const _tpsCsvPath = '../docker/bench/outputs/legacy/pool-topology-tps.csv';
const _outTps = '../docker/bench/outputs/legacy/pool-topology-tps.svg';
const _outP99 = '../docker/bench/outputs/legacy/pool-topology-p99.svg';

const _topologies = ['1x16', '2x8', '4x4', '8x2', '16x1'];
const _drivers = ['native', 'postgres'];

class _Sample {
  final int runId;
  final String driver;
  final String txType;
  final int latencyUs;
  final bool success;
  final int? workerId;
  final String topology;
  _Sample(this.runId, this.driver, this.txType, this.latencyUs, this.success,
      this.workerId, this.topology);
}

void main() {
  final samples = _loadSamples(_csvPath);

  // Compute aggregates per (driver, topology).
  final tpsByKey = <String, double>{};
  final p99NewOrderByKey = <String, int>{};

  // TPS real (wall-clock per rep) vem do arquivo separado.
  final tpsLines = File(_tpsCsvPath).readAsLinesSync();
  final tpsRepData = <String, List<double>>{};
  for (final l in tpsLines.skip(1).where((l) => l.isNotEmpty)) {
    final p = l.split(',');
    final key = '${p[0]}|${p[1]}';
    tpsRepData.putIfAbsent(key, () => []).add(double.parse(p[5]));
  }
  for (final entry in tpsRepData.entries) {
    final mean = entry.value.reduce((a, b) => a + b) / entry.value.length;
    tpsByKey[entry.key] = mean;
  }

  for (final driver in _drivers) {
    for (final topo in _topologies) {
      final filtered = samples
          .where((s) =>
              s.driver == driver && s.topology == topo && s.success)
          .toList();
      if (filtered.isEmpty) continue;

      // p99 NewOrder
      final newOrderLats =
          (filtered.where((s) => s.txType == 'newOrder').map((s) => s.latencyUs).toList())
            ..sort();
      if (newOrderLats.isNotEmpty) {
        final idx = (newOrderLats.length * 0.99)
            .round()
            .clamp(0, newOrderLats.length - 1);
        p99NewOrderByKey['$driver|$topo'] = newOrderLats[idx];
      }
    }
  }

  print('=== TPS médio por topologia (wall-clock real per rep) ===');
  for (final t in _topologies) {
    print('$t: native=${tpsByKey['native|$t']?.toStringAsFixed(0) ?? '?'} '
        'postgres=${tpsByKey['postgres|$t']?.toStringAsFixed(0) ?? '?'}');
  }

  print('\n=== p99 newOrder (μs) ===');
  for (final t in _topologies) {
    print('$t: native=${p99NewOrderByKey['native|$t'] ?? '?'} '
        'postgres=${p99NewOrderByKey['postgres|$t'] ?? '?'}');
  }

  // Render SVGs.
  File(_outTps).writeAsStringSync(_renderBarSvg(
    title: 'Pool topology sweep — TPS por topologia (drivers comparados)',
    subtitle: '5 topologias × 2 drivers × 3 reps × 5000 tx · TPS = wall-clock per rep (max over reps)',
    values: tpsByKey,
    yLabel: 'TPS',
    yFormat: (v) => v.toStringAsFixed(0),
  ));
  print('\n[svg] $_outTps');

  final p99Doubles = <String, double>{
    for (final k in p99NewOrderByKey.keys) k: p99NewOrderByKey[k]!.toDouble(),
  };
  File(_outP99).writeAsStringSync(_renderBarSvg(
    title: 'Pool topology sweep — p99 NewOrder latency por topologia',
    subtitle: '5 topologias × 2 drivers · p99 sobre samples agregados',
    values: p99Doubles,
    yLabel: 'p99 (μs)',
    yFormat: (v) => v.toStringAsFixed(0),
  ));
  print('[svg] $_outP99');
}

List<_Sample> _loadSamples(String path) {
  final lines = File(path).readAsLinesSync();
  return lines.skip(1).where((l) => l.isNotEmpty).map((l) {
    final p = l.split(',');
    return _Sample(
      int.parse(p[0]),
      p[1],
      p[2],
      int.parse(p[3]),
      p[4] == '1',
      p[5].isEmpty ? null : int.parse(p[5]),
      p[6],
    );
  }).toList();
}

String _renderBarSvg({
  required String title,
  required String subtitle,
  required Map<String, double> values,
  required String yLabel,
  required String Function(double) yFormat,
}) {
  const w = 1100;
  const h = 520;
  const margin = 80;
  final chartTop = 90.0;
  final chartBottom = h - 110.0;
  final chartH = chartBottom - chartTop;
  final chartW = (w - 2 * margin).toDouble();

  var maxY = 0.0;
  for (final v in values.values) {
    if (v > maxY) maxY = v;
  }
  maxY *= 1.15;

  const barW = 60.0;
  const gap = 20.0;
  const groupGap = 30.0;
  final groupW = 2 * barW + gap;
  final totalGroups = _topologies.length;
  final marginInner =
      (chartW - totalGroups * groupW - (totalGroups - 1) * groupGap) / 2;

  final svg = StringBuffer();
  svg.writeln(
      '<svg xmlns="http://www.w3.org/2000/svg" width="$w" height="$h" viewBox="0 0 $w $h" font-family="system-ui,-apple-system,sans-serif" font-size="12">');
  svg.writeln('<rect width="$w" height="$h" fill="white"/>');
  svg.writeln(
      '<text x="${w / 2}" y="32" text-anchor="middle" font-size="18" font-weight="bold">$title</text>');
  svg.writeln(
      '<text x="${w / 2}" y="54" text-anchor="middle" font-size="11" fill="#555">$subtitle</text>');

  for (var i = 0; i <= 5; i++) {
    final y = chartBottom - (i / 5) * chartH;
    final v = (i / 5 * maxY);
    svg.writeln(
        '<line x1="$margin" y1="$y" x2="${w - margin}" y2="$y" stroke="#eee"/>');
    svg.writeln(
        '<text x="${margin - 6}" y="${y + 4}" text-anchor="end" fill="#666">${yFormat(v)}</text>');
  }
  svg.writeln(
      '<text x="${margin - 50}" y="${chartTop - 15}" fill="#666" font-size="10">$yLabel</text>');

  for (var ti = 0; ti < _topologies.length; ti++) {
    final topo = _topologies[ti];
    final groupX = margin + marginInner + ti * (groupW + groupGap);

    for (var di = 0; di < _drivers.length; di++) {
      final driver = _drivers[di];
      final v = values['$driver|$topo'] ?? 0;
      final barH = (v / maxY) * chartH;
      final x = groupX + di * (barW + gap);
      final y = chartBottom - barH;
      final color = driver == 'native' ? '#1e88e5' : '#fb8c00';
      svg.writeln(
          '<rect x="$x" y="$y" width="$barW" height="$barH" fill="$color"/>');
      svg.writeln(
          '<text x="${x + barW / 2}" y="${y - 4}" text-anchor="middle" font-size="10" fill="#333">${yFormat(v)}</text>');
    }

    svg.writeln(
        '<text x="${groupX + groupW / 2}" y="${chartBottom + 22}" text-anchor="middle" font-weight="bold">$topo</text>');
  }

  svg.writeln(
      '<line x1="$margin" y1="$chartBottom" x2="${w - margin}" y2="$chartBottom" stroke="#333"/>');

  // Legend
  final legY = h - 35;
  svg.writeln(
      '<rect x="${w / 2 - 130}" y="${legY - 12}" width="14" height="14" fill="#1e88e5"/>');
  svg.writeln(
      '<text x="${w / 2 - 110}" y="$legY">dart_db_connector (native)</text>');
  svg.writeln(
      '<rect x="${w / 2 + 50}" y="${legY - 12}" width="14" height="14" fill="#fb8c00"/>');
  svg.writeln(
      '<text x="${w / 2 + 70}" y="$legY">postgres package</text>');

  svg.writeln('</svg>');
  return svg.toString();
}
