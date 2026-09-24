import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';

const _blue = Color(0xFF4D8DFF);
const _purple = Color(0xFFA459F7);
const _pink = Color(0xFFFF5C9C);
const _orange = Color(0xFFF59E0B);
const _red = Color(0xFFE5484D);
const _teal = Color(0xFF14B8A6);

final _numFormat = NumberFormat('#,##0', 'en_US');
String _num(num v) => _numFormat.format(v.round()).replaceAll(',', ' ');

class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportData {
  _ReportData({
    required this.report,
    required this.previous,
    required this.dashboard,
    required this.products,
    required this.shift,
    required this.shiftTotals,
    required this.resources,
    required this.sessions,
  });

  final Map<String, dynamic> report;
  final Map<String, dynamic> previous;
  final Map<String, dynamic> dashboard;
  final List<Map<String, dynamic>> products;
  final Map<String, dynamic>? shift;
  final Map<String, dynamic>? shiftTotals;
  final List<Map<String, dynamic>> resources;
  final List<Map<String, dynamic>> sessions;
}

class _ReportsPageState extends State<ReportsPage> {
  int period = 0;

  static const _periodNames = ['Bugun', 'Hafta', 'Oy', 'Yil'];

  String get _bucket => switch (period) {
        0 => 'hour',
        3 => 'month',
        _ => 'day',
      };

  DateTime _start(DateTime now) => switch (period) {
        1 => DateTime(now.year, now.month, now.day - 6),
        2 => DateTime(now.year, now.month),
        3 => DateTime(now.year),
        _ => DateTime(now.year, now.month, now.day),
      };

  /// Same point in time one period earlier -- the comparison window is
  /// "previous period up to the same moment", so a Tuesday-noon weekly
  /// number isn't compared against a whole finished week.
  DateTime _back(DateTime d) {
    DateTime shiftMonths(int months) {
      final target = DateTime(d.year, d.month - months);
      final lastDay = DateTime(target.year, target.month + 1, 0).day;
      return DateTime(target.year, target.month, math.min(d.day, lastDay),
          d.hour, d.minute, d.second);
    }

    return switch (period) {
      1 => DateTime(d.year, d.month, d.day - 7, d.hour, d.minute, d.second),
      2 => shiftMonths(1),
      3 => shiftMonths(12),
      _ => DateTime(d.year, d.month, d.day - 1, d.hour, d.minute, d.second),
    };
  }

  Future<_ReportData> _load() async {
    final repo = widget.controller.repository;
    final clubId = widget.controller.context!.clubId;
    final now = DateTime.now();
    final from = _start(now);
    final results = await Future.wait([
      repo.periodReport(clubId, from, now),
      repo.periodReport(clubId, _back(from), _back(now)),
      repo.reportDashboard(clubId, from, now, _bucket),
      repo.products(clubId),
      repo.shifts(clubId),
      repo.resources(clubId),
      repo.activeSessions(clubId),
    ]);
    final shifts = results[4] as List<Map<String, dynamic>>;
    final shift = shifts.where((s) => s['status'] == 'OPEN').firstOrNull;
    final totals =
        shift == null ? null : await repo.shiftTotals('${shift['id']}');
    return _ReportData(
      report: results[0] as Map<String, dynamic>,
      previous: results[1] as Map<String, dynamic>,
      dashboard: results[2] as Map<String, dynamic>,
      products: results[3] as List<Map<String, dynamic>>,
      shift: shift,
      shiftTotals: totals,
      resources: results[5] as List<Map<String, dynamic>>,
      sessions: results[6] as List<Map<String, dynamic>>,
    );
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(26, 20, 24, 20),
        child: AsyncPane<_ReportData>(
          future: _load(),
          builder: (context, data) => LayoutBuilder(
            builder: (context, box) => ListView(
              children: [
                _header(data),
                const SizedBox(height: 16),
                _shiftRow(data, box.maxWidth),
                const SizedBox(height: 20),
                _periodChips(),
                const SizedBox(height: 18),
                _kpiRow(data, box.maxWidth),
                const SizedBox(height: 18),
                _chartGrid(data, box.maxWidth),
                const SizedBox(height: 18),
                _clubRow(data, box.maxWidth),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      );

  Widget _header(_ReportData data) {
    final opened = DateTime.tryParse('${data.shift?['opened_at']}')?.toLocal();
    return PageHeader(
      title: tr('Hisobotlar'),
      subtitle: opened == null
          ? tr('Smena yopiq')
          : '${tr('Ochilgan')}: ${DateFormat('dd.MM, HH:mm').format(opened)}',
      actions: [
        IconButton(
          onPressed: () => setState(() {}),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
  }

  Widget _shiftRow(_ReportData data, double width) {
    final totals = data.shiftTotals;
    final revenue = (totals?['revenue'] ?? totals?['total'] ?? 0) as num;
    final orders = (totals?['orders_count'] as num?)?.toInt() ?? 0;
    final expected =
        (totals?['expected_cash'] ?? data.shift?['expected_cash'] ?? 0) as num;
    final profile = data.shift?['profiles'];
    final cashier = profile is Map ? '${profile['full_name'] ?? ''}' : '';
    final cards = [
      _ShiftCard(
        label: tr('SMENA TUSHUMI'),
        value: data.shift == null ? '—' : _num(revenue),
        sub: data.shift == null
            ? tr('Smena yopiq')
            : '${tr('Buyurtmalar')}: $orders${cashier.isEmpty ? '' : ' · $cashier'}',
      ),
      _ShiftCard(
        label: tr("O'RTACHA CHEK"),
        value: data.shift == null || orders == 0 ? '—' : _num(revenue / orders),
        sub: tr("so'm"),
      ),
      _ShiftCard(
        label: tr("KASSADA BO'LISHI KERAK"),
        value: data.shift == null ? '—' : _num(expected),
        sub: tr("so'm"),
      ),
    ];
    return _grid(cards, width, 3, 14);
  }

  Widget _periodChips() => Wrap(
        spacing: 10,
        children: [
          for (var i = 0; i < _periodNames.length; i++)
            _PeriodChip(
              label: tr(_periodNames[i]),
              selected: period == i,
              onTap: () => setState(() => period = i),
            ),
        ],
      );

  Widget _kpiRow(_ReportData data, double width) {
    final r = data.report;
    final p = data.previous;
    num n(Map<String, dynamic> m, String key) => (m[key] as num?) ?? 0;
    final revenue = n(r, 'revenue');
    final orders = n(r, 'orders_count');
    final avg = orders == 0 ? 0 : revenue / orders;
    final prevOrders = n(p, 'orders_count');
    final prevAvg = prevOrders == 0 ? 0 : n(p, 'revenue') / prevOrders;
    final periodLabel = tr(_periodNames[period]).toUpperCase();

    final cards = [
      _KpiCard(
        icon: Icons.account_balance_wallet_outlined,
        color: _blue,
        label: '${tr('TUSHUM')} · $periodLabel',
        value: _num(revenue),
        sub: tr("so'm"),
        change: _change(revenue, n(p, 'revenue')),
      ),
      _KpiCard(
        icon: Icons.home_outlined,
        color: VColors.green,
        label: '${tr('FOYDA')} · $periodLabel',
        value: _num(n(r, 'net_profit')),
        valueColor: VColors.green,
        sub: tr("so'm"),
        change: _change(n(r, 'net_profit'), n(p, 'net_profit')),
      ),
      _KpiCard(
        icon: Icons.shopping_cart_outlined,
        color: VColors.green,
        label: '${tr('BUYURTMALAR')} · $periodLabel',
        value: _num(orders),
        sub: '${tr("O'rtacha chek")}: ${_num(avg)}',
        change: _change(orders, prevOrders),
      ),
      _KpiCard(
        icon: Icons.trending_up_rounded,
        color: _purple,
        label: '${tr("O'RTACHA CHEK")} · $periodLabel',
        value: _num(avg),
        sub: tr("so'm"),
        change: _change(avg, prevAvg),
      ),
      _KpiCard(
        icon: Icons.inventory_2_outlined,
        color: _pink,
        label: '${tr('SOTILGAN TOVARLAR')} · $periodLabel',
        value: _num(n(r, 'products_qty')),
        sub: tr('dona'),
        change: _change(n(r, 'products_qty'), n(p, 'products_qty')),
      ),
    ];
    return _grid(cards, width, width >= 1250 ? 5 : 3, 14);
  }

  int? _change(num current, num previous) {
    if (previous <= 0) return null;
    return ((current - previous) / previous * 100).round();
  }

  Widget _chartGrid(_ReportData data, double width) {
    final series = ((data.dashboard['series'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final labels = series.map((s) => _bucketLabel('${s['at']}')).toList();
    final revenue =
        series.map((s) => ((s['revenue'] as num?) ?? 0).toDouble()).toList();
    final orders =
        series.map((s) => ((s['orders'] as num?) ?? 0).toDouble()).toList();
    final average = [
      for (var i = 0; i < series.length; i++)
        orders[i] == 0 ? 0.0 : revenue[i] / orders[i]
    ];
    final revenueTitle = switch (_bucket) {
      'hour' => "Soatlar bo'yicha tushum",
      'month' => "Oylar bo'yicha tushum",
      _ => "Kunlar bo'yicha tushum",
    };

    final cards = [
      _ChartCard(
        title: tr(revenueTitle),
        child: _LineChart(values: revenue, labels: labels, color: VColors.green),
      ),
      _ChartCard(
        title: tr('Sotuvlar tarkibi'),
        child: _Composition(
          rows: ((data.dashboard['composition'] as List?) ?? const [])
              .cast<Map<String, dynamic>>(),
          total: (data.report['revenue'] as num?) ?? 0,
        ),
      ),
      _ChartCard(
        title: tr('Skladdagi qoldiq'),
        child: _StockList(
          products: data.products,
          onOpen: () => widget.controller.go(7),
        ),
      ),
      _ChartCard(
        title: tr("O'rtacha chek"),
        child: _LineChart(values: average, labels: labels, color: _purple),
      ),
      _ChartCard(
        title: tr('Buyurtmalar soni'),
        child: _LineChart(values: orders, labels: labels, color: _blue),
      ),
      _ChartCard(
        title: tr("Tushum bo'yicha eng yaxshi tovarlar"),
        child: _TopProducts(
          rows: ((data.dashboard['top_products'] as List?) ?? const [])
              .cast<Map<String, dynamic>>(),
        ),
      ),
    ];
    return _grid(cards, width, width >= 1100 ? 3 : 2, 16);
  }

  String _bucketLabel(String raw) {
    final d = DateTime.tryParse(raw);
    if (d == null) return raw;
    return switch (_bucket) {
      'hour' => '${d.hour.toString().padLeft(2, '0')}:00',
      'month' => (LocaleController.instance.isRu
          ? const ['Янв', 'Фев', 'Мар', 'Апр', 'Май', 'Июн', 'Июл', 'Авг', 'Сен', 'Окт', 'Ноя', 'Дек']
          : const ['Yan', 'Fev', 'Mar', 'Apr', 'May', 'Iyn', 'Iyl', 'Avg', 'Sen', 'Okt', 'Noy', 'Dek'])[d.month - 1],
      _ => DateFormat('dd.MM').format(d),
    };
  }

  Widget _clubRow(_ReportData data, double width) {
    final r = data.report;
    num n(String key) => (r[key] as num?) ?? 0;
    final busyIds = {for (final s in data.sessions) '${s['resource_id']}'};
    final busy = data.resources
        .where((row) =>
            busyIds.contains('${row['id']}') || row['status'] != 'FREE')
        .length;
    final cards = [
      _MiniStat(
          label: tr('Vaqt tushumi'),
          value: _num(n('time_billiard') + n('time_playstation')),
          color: _blue),
      _MiniStat(
          label: tr('Bar foydasi'), value: _num(n('bar_profit')), color: VColors.green),
      _MiniStat(label: tr('Xarajatlar'), value: _num(n('expenses')), color: _red),
      _MiniStat(
          label: tr('Hozirgi bandlik'),
          value: '$busy / ${data.resources.length}',
          color: _orange,
          progress: data.resources.isEmpty ? 0 : busy / data.resources.length),
    ];
    return _grid(cards, width, 4, 14);
  }

  Widget _grid(List<Widget> children, double width, int cols, double gap) {
    final itemWidth = (width - gap * (cols - 1)) / cols;
    return Wrap(
      spacing: gap,
      runSpacing: gap,
      children: [
        for (final child in children) SizedBox(width: itemWidth, child: child),
      ],
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding = const EdgeInsets.all(20)});
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: VColors.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: VColors.line),
        ),
        child: child,
      );
}

TextStyle _capsStyle() => TextStyle(
    color: VColors.muted,
    fontSize: 12.5,
    fontWeight: FontWeight.w800,
    letterSpacing: .8);

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.label, required this.value, required this.sub});
  final String label, value, sub;

  @override
  Widget build(BuildContext context) => _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: _capsStyle()),
            const SizedBox(height: 10),
            Text(value,
                style:
                    const TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
            const SizedBox(height: 6),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: VColors.muted, fontSize: 14)),
          ],
        ),
      );
}

class _PeriodChip extends StatelessWidget {
  const _PeriodChip(
      {required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            color: selected
                ? VColors.green.withValues(alpha: .12)
                : VColors.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
                color: selected ? VColors.green : VColors.line,
                width: selected ? 1.5 : 1),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 15,
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? VColors.green : VColors.ink)),
        ),
      );
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.icon,
    required this.color,
    required this.label,
    required this.value,
    required this.sub,
    this.change,
    this.valueColor,
  });

  final IconData icon;
  final Color color;
  final String label, value, sub;
  final int? change;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) => _Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                  child: Icon(icon, color: Colors.white, size: 21),
                ),
                const Spacer(),
                if (change != null) _ChangeBadge(change!),
              ],
            ),
            const SizedBox(height: 18),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _capsStyle()),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value,
                  style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w900,
                      color: valueColor ?? VColors.ink)),
            ),
            const SizedBox(height: 6),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: VColors.muted, fontSize: 14)),
          ],
        ),
      );
}

class _ChangeBadge extends StatelessWidget {
  const _ChangeBadge(this.value);
  final int value;

  @override
  Widget build(BuildContext context) {
    final up = value >= 0;
    final color = up ? VColors.green : _red;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .14),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text('${up ? '↑' : '↓'} ${value.abs()}%',
          style: TextStyle(
              color: color, fontWeight: FontWeight.w800, fontSize: 12.5)),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox(
        height: 400,
        child: _Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 17.5, fontWeight: FontWeight.w900)),
              const SizedBox(height: 18),
              Expanded(child: child),
            ],
          ),
        ),
      );
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) => Center(
      child: Text(tr("Ma'lumot yo'q"), style: TextStyle(color: VColors.subtle)));
}

class _LineChart extends StatelessWidget {
  const _LineChart(
      {required this.values, required this.labels, required this.color});
  final List<double> values;
  final List<String> labels;
  final Color color;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) return const _Empty();
    return CustomPaint(
      size: Size.infinite,
      painter: _LinePainter(
        values: values,
        labels: labels,
        color: color,
        gridColor: VColors.line,
        textColor: VColors.subtle,
      ),
    );
  }
}

double _niceCeil(double v) {
  if (v <= 0) return 1;
  final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
  final f = v / exp;
  const steps = [1.0, 2.0, 2.5, 4.0, 5.0, 8.0, 10.0];
  final nice = steps.firstWhere((s) => f <= s + 1e-9, orElse: () => 10);
  return nice * exp;
}

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.values,
    required this.labels,
    required this.color,
    required this.gridColor,
    required this.textColor,
  });

  final List<double> values;
  final List<String> labels;
  final Color color, gridColor, textColor;

  TextPainter _text(String s) => TextPainter(
        text: TextSpan(text: s, style: TextStyle(color: textColor, fontSize: 10.5)),
        textDirection: TextDirection.ltr,
      )..layout();

  @override
  void paint(Canvas canvas, Size size) {
    const left = 58.0, bottom = 22.0, top = 6.0, right = 10.0;
    final chart = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final maxValue = _niceCeil(values.reduce(math.max));
    const gridLines = 4;

    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= gridLines; i++) {
      final y = chart.bottom - chart.height * i / gridLines;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
      final label = _text(_num(maxValue * i / gridLines));
      label.paint(canvas, Offset(chart.left - label.width - 8, y - label.height / 2));
    }

    final n = values.length;
    double xAt(int i) =>
        n == 1 ? chart.center.dx : chart.left + chart.width * i / (n - 1);
    double yAt(double v) => chart.bottom - chart.height * (v / maxValue);

    final every = math.max(1, (n / 8).ceil());
    for (var i = 0; i < n; i++) {
      final isLast = i == n - 1;
      if (i % every != 0 && !(isLast && (n - 1) % every >= every / 2)) continue;
      final label = _text(labels[i]);
      label.paint(canvas, Offset(xAt(i) - label.width / 2, chart.bottom + 6));
    }

    final line = Path()..moveTo(xAt(0), yAt(values[0]));
    for (var i = 1; i < n; i++) {
      line.lineTo(xAt(i), yAt(values[i]));
    }
    final area = Path.from(line)
      ..lineTo(xAt(n - 1), chart.bottom)
      ..lineTo(xAt(0), chart.bottom)
      ..close();
    canvas.drawPath(
      area,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: .28), color.withValues(alpha: .02)],
        ).createShader(chart),
    );
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
    if (n <= 31) {
      final dot = Paint()..color = color;
      for (var i = 0; i < n; i++) {
        canvas.drawCircle(Offset(xAt(i), yAt(values[i])), 3.2, dot);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.values != values || old.color != color || old.gridColor != gridColor;
}

const _segmentColors = [
  Color(0xFF22A06B),
  _red,
  _blue,
  _pink,
  _orange,
  _purple,
  _teal,
];

class _Composition extends StatelessWidget {
  const _Composition({required this.rows, required this.total});
  final List<Map<String, dynamic>> rows;
  final num total;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _Empty();
    const maxSegments = 5;
    final segments = <MapEntry<String, double>>[
      for (final r in rows.take(maxSegments))
        MapEntry(tr('${r['label']}'), ((r['amount'] as num?) ?? 0).toDouble()),
    ];
    if (rows.length > maxSegments) {
      final rest = rows
          .skip(maxSegments)
          .fold<double>(0, (s, r) => s + ((r['amount'] as num?) ?? 0).toDouble());
      segments.add(MapEntry(tr('Boshqa'), rest));
    }
    final sum = segments.fold<double>(0, (s, e) => s + e.value);

    return LayoutBuilder(builder: (context, box) {
      final ring = math.min(box.maxHeight, box.maxWidth * .48);
      return Row(
        children: [
          SizedBox(
            width: ring,
            height: ring,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CustomPaint(
                  size: Size.square(ring),
                  painter: _DonutPainter(
                    values: segments.map((e) => e.value).toList(),
                    colors: _segmentColors,
                    track: VColors.field,
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FittedBox(
                      child: Text(_num(total),
                          style: const TextStyle(
                              fontSize: 24, fontWeight: FontWeight.w900)),
                    ),
                    Text(tr("so'm"),
                        style: TextStyle(color: VColors.muted, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < segments.length; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 7),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: _segmentColors[i % _segmentColors.length],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(segments[i].key,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 14.5)),
                        ),
                        Text(
                            sum == 0
                                ? '0%'
                                : '${(segments[i].value / sum * 100).round()}%',
                            style: TextStyle(
                                color: VColors.muted,
                                fontWeight: FontWeight.w800)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.values, required this.colors, required this.track});
  final List<double> values;
  final List<Color> colors;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.shortestSide * .13;
    final rect = Rect.fromCircle(
        center: size.center(Offset.zero),
        radius: size.shortestSide / 2 - stroke / 2);
    final base = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawArc(rect, 0, math.pi * 2, false, base..color = track);
    final sum = values.fold<double>(0, (s, v) => s + v);
    if (sum <= 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / sum * math.pi * 2;
      canvas.drawArc(rect, start, sweep, false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..color = colors[i % colors.length]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.values != values || old.track != track;
}

class _StockList extends StatelessWidget {
  const _StockList({required this.products, required this.onOpen});
  final List<Map<String, dynamic>> products;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final tracked = products
        .where((p) => p['track_stock'] != false && p['active'] != false)
        .toList()
      ..sort((a, b) => ((a['stock_quantity'] as num?) ?? 0)
          .compareTo((b['stock_quantity'] as num?) ?? 0));
    final maxStock = tracked.fold<double>(
        1, (m, p) => math.max(m, ((p['stock_quantity'] as num?) ?? 0).toDouble()));
    final shown = tracked.take(5).toList();

    return Column(
      children: [
        Expanded(
          child: shown.isEmpty
              ? const _Empty()
              : Column(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (final p in shown) _stockRow(p, maxStock),
                  ],
                ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 46,
          child: OutlinedButton(
            onPressed: onOpen,
            style: OutlinedButton.styleFrom(
              foregroundColor: VColors.ink,
              side: BorderSide(color: VColors.line),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
              textStyle:
                  const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
            ),
            child: Text(tr("Skladga o'tish")),
          ),
        ),
      ],
    );
  }

  Widget _stockRow(Map<String, dynamic> p, double maxStock) {
    final stock = ((p['stock_quantity'] as num?) ?? 0).toDouble();
    final minimum = ((p['minimum_stock'] as num?) ?? 0).toDouble();
    final low = minimum > 0 ? stock <= minimum : stock <= 0;
    final color = low ? _red : VColors.green;
    final unit = '${p['unit'] ?? tr('dona')}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('${p['name']}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 14.5)),
            ),
            Text('${_num(stock)} $unit',
                style: TextStyle(
                    fontWeight: FontWeight.w900, color: low ? _red : null)),
          ],
        ),
        const SizedBox(height: 7),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: math.max(.02, (stock / maxStock).clamp(0, 1)).toDouble(),
            minHeight: 7,
            backgroundColor: VColors.field,
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

class _TopProducts extends StatelessWidget {
  const _TopProducts({required this.rows});
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) return const _Empty();
    final maxRevenue = rows.fold<double>(
        1, (m, r) => math.max(m, ((r['revenue'] as num?) ?? 0).toDouble()));
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        for (final r in rows)
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 34,
                  child: Stack(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: VColors.field,
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      FractionallySizedBox(
                        widthFactor: math
                            .max(.08,
                                ((r['revenue'] as num?) ?? 0) / maxRevenue)
                            .toDouble()
                            .clamp(0.0, 1.0),
                        child: Container(
                          decoration: BoxDecoration(
                            color: VColors.green.withValues(alpha: .28),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 11),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text.rich(
                            TextSpan(children: [
                              TextSpan(
                                  text: '${r['name']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w600)),
                              TextSpan(
                                  text: '  × ${_num((r['qty'] as num?) ?? 0)}',
                                  style: TextStyle(color: VColors.muted)),
                            ]),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 96,
                child: Text(_num((r['revenue'] as num?) ?? 0),
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 15)),
              ),
            ],
          ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.label,
      required this.value,
      required this.color,
      this.progress});
  final String label, value;
  final Color color;
  final double? progress;

  @override
  Widget build(BuildContext context) => _Panel(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 6,
              height: 42,
              decoration: BoxDecoration(
                  color: color, borderRadius: BorderRadius.circular(3)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: VColors.muted, fontSize: 13.5)),
                  const SizedBox(height: 4),
                  Text(value,
                      style: const TextStyle(
                          fontSize: 21, fontWeight: FontWeight.w900)),
                  if (progress != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress!.clamp(0.0, 1.0),
                        minHeight: 5,
                        backgroundColor: VColors.field,
                        valueColor: AlwaysStoppedAnimation(color),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
}
