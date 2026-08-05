/// Renders the `driver_us` attribution CSV as a hand-rolled SVG
/// (Dart-first, no matplotlib — per `benchmark_protocol_rule` §4.7).
///
/// Grouped horizontal bars of the p50 of each phase (submit/wait/decode)
/// per (shape × topology), on a **log10 µs** axis because `wait`
/// (round-trip + scheduling) dwarfs the CPU-controllable submit/decode by
/// two orders of magnitude — a linear axis would hide exactly the phases
/// the codec plan cares about.
///
/// Run (from `benchmarks/`):
///   dart run scripts/plot_attribution.dart \
///     outputs/driver-us-attribution.csv
/// Writes `<input>.svg` next to the CSV.
library;

import 'dart:io';
import 'dart:math' as math;

const _phaseColors = {
  'submit': '#4C78A8',
  'wait': '#E45756',
  'decode': '#54A24B',
};

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('usage: dart run scripts/plot_attribution.dart <csv>');
    exit(2);
  }
  final csvPath = args.first;
  final lines = File(csvPath).readAsLinesSync();
  final header = lines.first.split(',');
  final iShape = header.indexOf('shape');
  final iTopo = header.indexOf('topology');
  final iPhase = header.indexOf('phase');
  final iP50 = header.indexOf('p50_us');
  final iP99 = header.indexOf('p99_us');

  // (shape,topology) → {phase → (p50, p99)}
  final groups = <String, Map<String, (double, double)>>{};
  for (final line in lines.skip(1)) {
    final f = line.split(',');
    final phase = f[iPhase];
    if (!_phaseColors.containsKey(phase)) continue; // skip overhead rows
    final key = '${f[iShape]} / ${f[iTopo]}';
    final p50 = double.tryParse(f[iP50]) ?? 0;
    final p99 = double.tryParse(f[iP99]) ?? 0;
    (groups[key] ??= {})[phase] = (p50, p99);
  }

  final svg = _render(groups);
  final outPath = csvPath.replaceAll(RegExp(r'\.csv$'), '.svg');
  File(outPath).writeAsStringSync(svg);
  print('wrote $outPath');
}

String _render(Map<String, Map<String, (double, double)>> groups) {
  const width = 900.0;
  const left = 160.0, right = 40.0, top = 60.0, rowH = 22.0, groupGap = 16.0;
  const phases = ['submit', 'wait', 'decode'];

  final height = top + groups.length * (phases.length * rowH + groupGap) + 40;
  final plotW = width - left - right;

  // Log10 axis from 1 to the max p99 (ceil to a power of 10).
  var maxUs = 1.0;
  for (final g in groups.values) {
    for (final v in g.values) {
      maxUs = math.max(maxUs, math.max(v.$1, v.$2));
    }
  }
  final maxLog = math.max(1, (math.log(maxUs) / math.ln10).ceil());
  double x(double us) =>
      left + (us <= 1 ? 0 : (math.log(us) / math.ln10) / maxLog) * plotW;

  final b = StringBuffer();
  b.writeln('<svg xmlns="http://www.w3.org/2000/svg" width="$width" '
      'height="${height.toStringAsFixed(0)}" font-family="sans-serif" '
      'font-size="12">');
  b.writeln('<rect width="$width" height="${height.toStringAsFixed(0)}" '
      'fill="white"/>');
  b.writeln('<text x="$left" y="28" font-size="16" font-weight="bold">'
      'driver_us attribution — phase p50 (bar) + p99 (tick), log µs</text>');

  // Gridlines + axis labels at powers of 10.
  for (var e = 0; e <= maxLog; e++) {
    final us = math.pow(10, e).toDouble();
    final gx = x(us).toStringAsFixed(1);
    b.writeln('<line x1="$gx" y1="$top" x2="$gx" '
        'y2="${(height - 30).toStringAsFixed(0)}" stroke="#ddd"/>');
    b.writeln('<text x="$gx" y="${(height - 12).toStringAsFixed(0)}" '
        'text-anchor="middle" fill="#666">'
        '${us < 1000 ? us.toStringAsFixed(0) : "${(us / 1000).toStringAsFixed(0)}k"}µs</text>');
  }

  var y = top;
  final sortedKeys = groups.keys.toList()..sort();
  for (final key in sortedKeys) {
    b.writeln('<text x="8" y="${(y + rowH).toStringAsFixed(1)}" '
        'font-weight="bold">$key</text>');
    for (final phase in phases) {
      final v = groups[key]![phase];
      if (v != null) {
        final p50 = v.$1, p99 = v.$2;
        final x0 = x(0).toStringAsFixed(1);
        final x50 = x(p50).toStringAsFixed(1);
        final barW = (double.parse(x50) - double.parse(x0)).clamp(1.0, plotW);
        b.writeln('<rect x="$x0" y="${y.toStringAsFixed(1)}" '
            'width="${barW.toStringAsFixed(1)}" height="${rowH - 6}" '
            'fill="${_phaseColors[phase]}" opacity="0.85"/>');
        // p99 tick.
        final x99 = x(p99).toStringAsFixed(1);
        b.writeln('<line x1="$x99" y1="${y.toStringAsFixed(1)}" x2="$x99" '
            'y2="${(y + rowH - 6).toStringAsFixed(1)}" stroke="#333" '
            'stroke-width="1.5"/>');
        b.writeln('<text x="${(double.parse(x50) + 4).toStringAsFixed(1)}" '
            'y="${(y + rowH - 8).toStringAsFixed(1)}" fill="#333">'
            '$phase ${p50.toStringAsFixed(0)}µs</text>');
      }
      y += rowH;
    }
    y += groupGap;
  }
  b.writeln('</svg>');
  return b.toString();
}
