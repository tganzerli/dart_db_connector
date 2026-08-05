/// Renders the BEGIN-piggyback short-txn A/B CSV as a hand-rolled SVG
/// (Dart-first, no matplotlib — per `benchmark_protocol_rule` §4.7).
///
/// Two horizontal bars (eager vs fused) of the median-across-reps p50
/// latency on a linear µs axis (both arms are the same order of
/// magnitude, unlike the attribution chart). Each rep's p50 is overlaid
/// as a tick so the reader sees the spread; the p95 whisker and the Δ
/// annotation summarize the lever.
///
/// Run (from `benchmarks/`):
///   dart run scripts/plot_begin_piggyback.dart \
///     outputs/begin-piggyback-txn.csv
/// Writes `<input>.svg` next to the CSV.
library;

import 'dart:io';

const _armColors = {
  'eager': '#E45756', // pre-P5 (3 round-trips)
  'fused': '#54A24B', // P5 (2 round-trips)
};
const _armLabel = {
  'eager': 'eager  (BEGIN separado · 3 RTTs)',
  'fused': 'fused  (BEGIN fundido · 2 RTTs)',
};

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  if (n == 0) return 0;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run scripts/plot_begin_piggyback.dart <csv>');
    exit(2);
  }
  final csvPath = args.first;
  final lines = File(csvPath).readAsLinesSync();
  final header = lines.first.split(',');
  final iArm = header.indexOf('arm');
  final iP50 = header.indexOf('p50_us');
  final iP95 = header.indexOf('p95_us');
  final iMean = header.indexOf('mean_us');

  // arm → per-rep p50 / p95 / mean
  final p50s = <String, List<double>>{'eager': [], 'fused': []};
  final p95s = <String, List<double>>{'eager': [], 'fused': []};
  final means = <String, List<double>>{'eager': [], 'fused': []};
  for (final line in lines.skip(1)) {
    if (line.trim().isEmpty) continue;
    final f = line.split(',');
    final arm = f[iArm];
    if (!p50s.containsKey(arm)) continue;
    p50s[arm]!.add(double.parse(f[iP50]));
    p95s[arm]!.add(double.parse(f[iP95]));
    means[arm]!.add(double.parse(f[iMean]));
  }

  final svg = _render(p50s, p95s, means);
  final outPath = csvPath.replaceAll(RegExp(r'\.csv$'), '.svg');
  File(outPath).writeAsStringSync(svg);
  print('wrote $outPath');
}

String _render(Map<String, List<double>> p50s, Map<String, List<double>> p95s,
    Map<String, List<double>> means) {
  const width = 900.0;
  const left = 120.0, right = 120.0, top = 70.0, rowH = 64.0;
  const arms = ['eager', 'fused'];

  final height = top + arms.length * rowH + 70;
  final plotW = width - left - right;

  final eP50 = _median(p50s['eager']!);
  final fP50 = _median(p50s['fused']!);
  final eMean = _median(means['eager']!);
  final fMean = _median(means['fused']!);
  final maxUs = [
    ...p95s['eager']!,
    ...p95s['fused']!,
  ].reduce((a, b) => a > b ? a : b);
  // Round axis up to a clean tick.
  final axisMax = ((maxUs / 200).ceil()) * 200.0;
  double x(double us) => left + (us / axisMax) * plotW;

  final dP50 = 100.0 * (fP50 - eP50) / eP50;
  final dMean = 100.0 * (fMean - eMean) / eMean;

  final b = StringBuffer();
  b.writeln('<svg xmlns="http://www.w3.org/2000/svg" width="$width" '
      'height="${height.toStringAsFixed(0)}" font-family="sans-serif" '
      'font-size="12">');
  b.writeln('<rect width="$width" height="${height.toStringAsFixed(0)}" '
      'fill="white"/>');
  b.writeln('<text x="$left" y="28" font-size="16" font-weight="bold">'
      'BEGIN piggyback (P5) — short-txn A/B · p50 (barra) + reps (ticks) '
      '+ p95 (whisker)</text>');
  b.writeln('<text x="$left" y="48" font-size="12" fill="#666">'
      '1×1 warm, interleaved · 5 reps × 5000 · host macOS M4 → PostgreSQL 16 '
      '(loopback)</text>');

  // Axis gridlines every 200 µs.
  for (var us = 0.0; us <= axisMax; us += 200) {
    final gx = x(us).toStringAsFixed(1);
    b.writeln('<line x1="$gx" y1="$top" x2="$gx" '
        'y2="${(height - 50).toStringAsFixed(0)}" stroke="#eee"/>');
    b.writeln('<text x="$gx" y="${(height - 32).toStringAsFixed(0)}" '
        'text-anchor="middle" fill="#666">${us.toStringAsFixed(0)}µs</text>');
  }

  var y = top;
  for (final arm in arms) {
    final p50 = arm == 'eager' ? eP50 : fP50;
    final mean = arm == 'eager' ? eMean : fMean;
    final p95 = _median(p95s[arm]!);
    final barTop = y + 10;
    const barH = 24.0;
    final x0 = x(0).toStringAsFixed(1);
    final xw = (x(p50) - x(0)).toStringAsFixed(1);
    b.writeln('<text x="8" y="${(barTop + 16).toStringAsFixed(1)}" '
        'font-weight="bold">$arm</text>');
    b.writeln('<rect x="$x0" y="${barTop.toStringAsFixed(1)}" width="$xw" '
        'height="$barH" fill="${_armColors[arm]}" opacity="0.85"/>');
    // p95 whisker.
    final x95 = x(p95).toStringAsFixed(1);
    b.writeln('<line x1="$x95" y1="${(barTop + 2).toStringAsFixed(1)}" '
        'x2="$x95" y2="${(barTop + barH - 2).toStringAsFixed(1)}" '
        'stroke="#333" stroke-width="1.5"/>');
    b.writeln('<line x1="$xw" y1="${(barTop + barH / 2).toStringAsFixed(1)}" '
        'x2="$x95" y2="${(barTop + barH / 2).toStringAsFixed(1)}" '
        'stroke="#333" stroke-width="1" stroke-dasharray="3,2"/>');
    // Per-rep p50 ticks (spread).
    for (final rep in p50s[arm]!) {
      final rx = x(rep).toStringAsFixed(1);
      b.writeln(
          '<circle cx="$rx" cy="${(barTop + barH + 12).toStringAsFixed(1)}" '
          'r="2.5" fill="#333" opacity="0.6"/>');
    }
    // Labels.
    b.writeln('<text x="${(x(p50) + 6).toStringAsFixed(1)}" '
        'y="${(barTop + 16).toStringAsFixed(1)}" font-weight="bold" '
        'fill="#333">p50 ${p50.toStringAsFixed(0)}µs</text>');
    b.writeln('<text x="8" y="${(barTop + barH + 16).toStringAsFixed(1)}" '
        'fill="#666" font-size="11">${_armLabel[arm]}  ·  mean '
        '${mean.toStringAsFixed(0)}µs  ·  TPS ${(1e6 / mean).toStringAsFixed(0)}'
        '</text>');
    y += rowH;
  }

  // Δ annotation.
  b.writeln('<text x="$left" y="${(height - 8).toStringAsFixed(0)}" '
      'font-weight="bold" fill="#54A24B">Δ p50 ${dP50.toStringAsFixed(1)}%   '
      'Δ mean ${dMean.toStringAsFixed(1)}%   (negativo = fused mais rápido; '
      'teto teórico −33% ao cortar 1 de 3 RTTs)</text>');
  b.writeln('</svg>');
  return b.toString();
}
