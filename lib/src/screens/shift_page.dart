import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

import '../i18n.dart';
import '../services/printer_service.dart';
import '../services/receipt_builder.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class ShiftPage extends StatelessWidget {
  const ShiftPage({super.key, required this.controller});
  final ClubController controller;
  @override
  Widget build(BuildContext context) => Padding(
      padding: pagePadding(context),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(title: tr('Smena')),
        const SizedBox(height: 24),
        Expanded(
            child: AsyncPane<List<Map<String, dynamic>>>(
                future:
                    controller.repository.shifts(controller.context!.clubId),
                builder: (context, rows) {
                  final current =
                      rows.where((r) => r['status'] == 'OPEN').firstOrNull;
                  final day = _workDay(DateTime.now());
                  final dayShifts = _shiftsIn(rows, day);
                  return FutureBuilder<_DayData>(
                      future: _loadDay(current, day),
                      builder: (context, snap) {
                        final t = snap.data?.shiftTotals ??
                            Map<String, dynamic>.from(
                                current?['totals'] as Map? ?? {});
                        final r = snap.data?.report ?? const {};
                        final isCashier = controller.context!.isCashier;
                        return ListView(children: [
                          if (current == null) ...[
                            EmptyState(
                                icon: Icons.point_of_sale_outlined,
                                title: tr('Smena yopiq'),
                                subtitle: tr(
                                    'Savdoni boshlash uchun smenani oching')),
                            const SizedBox(height: 20),
                            Center(
                                child: FilledButton.icon(
                                    onPressed: () => _open(context),
                                    icon: const Icon(Icons.lock_open_rounded),
                                    label: Text(tr('Smenani ochish')))),
                            const SizedBox(height: 28),
                          ],
                          _shiftsCard(day, dayShifts, current, t, isCashier),
                          const SizedBox(height: 20),
                          if (!isCashier) ...[
                            _dayTotalsCard(r),
                            const SizedBox(height: 20),
                          ],
                          // Depositing/withdrawing cash outside a sale is an
                          // easy way to quietly move money in or out of the
                          // drawer -- only owner/admin get it now, same as
                          // the shift totals and X-report right above.
                          if (current != null && !isCashier) ...[
                            Row(children: [
                              Expanded(
                                  child: OutlinedButton.icon(
                                      onPressed: () =>
                                          _cash(context, current, true),
                                      icon:
                                          const Icon(Icons.south_west_rounded),
                                      label: Text(tr('Kiritish')))),
                              const SizedBox(width: 14),
                              Expanded(
                                  child: OutlinedButton.icon(
                                      onPressed: () =>
                                          _cash(context, current, false),
                                      icon:
                                          const Icon(Icons.north_east_rounded),
                                      label: Text(tr('Chiqarish'))))
                            ]),
                            const SizedBox(height: 14),
                            SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                    onPressed: () =>
                                        _printX(context, current, t),
                                    icon: const Icon(Icons.print_outlined),
                                    label: Text(tr('X-hisobotni chop etish')))),
                            const SizedBox(height: 14),
                          ],
                          if (current != null)
                            SizedBox(
                                width: double.infinity,
                                child: FilledButton.icon(
                                    style: FilledButton.styleFrom(
                                        backgroundColor: VColors.red),
                                    onPressed: () =>
                                        _close(context, current, t),
                                    icon:
                                        const Icon(Icons.lock_outline_rounded),
                                    label: Text(tr('Smenani yopish'))))
                        ]);
                      });
                }))
      ]));

  /// The screen covers a working day, 07:00 to 07:00 the next morning --
  /// the same day the owner bot reports on -- so a night that runs past
  /// midnight, and a shift closed and reopened in it, stay in one view.
  static const _dayStartHour = 7;

  ({DateTime start, DateTime end}) _workDay(DateTime now) {
    var start = DateTime(now.year, now.month, now.day, _dayStartHour);
    if (now.isBefore(start)) {
      start = DateTime(now.year, now.month, now.day - 1, _dayStartHour);
    }
    return (
      start: start,
      end: DateTime(start.year, start.month, start.day + 1, _dayStartHour)
    );
  }

  /// Shifts that ran during the day, oldest first. Open/close test clicks
  /// under a minute are left out, as in the owner bot.
  List<Map<String, dynamic>> _shiftsIn(
      List<Map<String, dynamic>> rows, ({DateTime start, DateTime end}) day) {
    final list = rows.where((s) {
      final opened = DateTime.tryParse('${s['opened_at']}')?.toLocal();
      final closed = DateTime.tryParse('${s['closed_at']}')?.toLocal();
      if (opened == null || !opened.isBefore(day.end)) return false;
      if (closed == null) return s['status'] == 'OPEN';
      return closed.isAfter(day.start) &&
          closed.difference(opened) >= const Duration(minutes: 1);
    }).toList();
    list.sort((a, b) => '${a['opened_at']}'.compareTo('${b['opened_at']}'));
    return list;
  }

  Future<_DayData> _loadDay(Map<String, dynamic>? current,
      ({DateTime start, DateTime end}) day) async {
    final repo = controller.repository;
    final results = await Future.wait([
      repo.periodReport(controller.context!.clubId, day.start, DateTime.now()),
      if (current != null) repo.shiftTotals('${current['id']}'),
    ]);
    return _DayData(results[0], results.length > 1 ? results[1] : null);
  }

  String _name(dynamic profile) =>
      profile is Map ? '${profile['full_name'] ?? ''}' : '';

  Widget _shiftsCard(
      ({DateTime start, DateTime end}) day,
      List<Map<String, dynamic>> shifts,
      Map<String, dynamic>? current,
      Map<String, dynamic> currentTotals,
      bool isCashier) {
    final entries = <Widget>[];
    for (final s in shifts) {
      final open = s['status'] == 'OPEN';
      final opener = _name(s['profiles']);
      final closer = _name(s['closer']);
      final expected = open && s['id'] == current?['id']
          ? currentTotals['expected_cash'] ?? s['expected_cash']
          : s['expected_cash'];
      if (entries.isNotEmpty) entries.add(const SizedBox(height: 18));
      entries.addAll([
        _row(tr('Ochilgan'),
            '${shortDate(s['opened_at'])}${opener.isEmpty ? '' : ' · $opener'}'),
        _row(
            tr('Yopilgan'),
            open
                ? tr('Smena davom etmoqda')
                : '${shortDate(s['closed_at'])}${closer.isEmpty ? '' : ' · $closer'}'),
        if (!isCashier && expected != null)
          _row(tr("Kassada bo'lishi kerak"), money(expected), bold: true),
        if (!isCashier && !open && s['actual_cash'] != null) ...[
          _row(tr('Topshirildi'), money(s['actual_cash'])),
          if (((s['difference'] as num?) ?? 0) != 0)
            _row((s['difference'] as num) > 0 ? tr('Ortiqcha') : tr('Kamomad'),
                money(s['difference']),
                bold: true, valueColor: VColors.red),
        ],
      ]);
    }
    return VCard(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('${tr('Ish kuni')} ${DateFormat('dd.MM.yyyy').format(day.start)}',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      if (entries.isEmpty)
        Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Text(tr('Smena ochilmagan'),
                style: TextStyle(color: VColors.muted, fontSize: 16)))
      else
        ...entries,
    ]));
  }

  Widget _dayTotalsCard(Map<String, dynamic> r) {
    num n(String key) => (r[key] as num?) ?? 0;
    final byMethod =
        Map<String, dynamic>.from(r['by_payment_method'] as Map? ?? {});
    return VCard(
        child: Column(children: [
      _row(tr('Buyurtmalar'), '${n('orders_count').toInt()}'),
      for (final e in byMethod.entries) _row(e.key, money(e.value)),
      _row(tr('Tushum'), money(n('revenue')), bold: true),
      _row(tr('Tannarx'), money(n('products_cost'))),
      _row(tr('Foyda'), money(n('revenue') - n('products_cost')), bold: true),
      _row(tr('Xarajatlar'), money(n('expenses'))),
      _row(tr('Sof foyda'), money(n('net_profit')), bold: true),
    ]));
  }

  Widget _row(String a, String b, {bool bold = false, Color? valueColor}) =>
      Container(
          padding: const EdgeInsets.symmetric(vertical: 9),
          decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: VColors.line))),
          child: InfoRow(a, b, bold: bold, valueColor: valueColor));
  Future<void> _printX(BuildContext context, Map<String, dynamic> current,
      Map<String, dynamic> totals) async {
    try {
      final config = await PrinterConfig.load();
      if (!config.isConfigured) {
        if (context.mounted) {
          showError(context, tr('Printer sozlanmagan — Sozlamalar → Chek'));
        }
        return;
      }
      final bytes = buildShiftXReport(
        club: controller.context!.club,
        cashierName: controller.context!.userName,
        openedAt:
            DateTime.tryParse('${current['opened_at']}') ?? DateTime.now(),
        totals: totals,
      );
      await PrinterService.print(config, bytes);
      if (context.mounted) showDone(context, tr('Hisobot chop etildi'));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _open(BuildContext context) async {
    final c = TextEditingController(text: '0');
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(tr('Smenani ochish')),
                content: TextField(
                    controller: c,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                        labelText: tr('Boshlang\'ich naqd pul'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('Bekor qilish'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Ochish')))
                ]));
    if (ok == true) {
      try {
        await controller.repository.client.rpc('open_cash_shift', params: {
          'p_club_id': controller.context!.clubId,
          'p_opening_cash': int.tryParse(c.text) ?? 0
        });
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _cash(
      BuildContext context, Map<String, dynamic> s, bool input) async {
    final a = TextEditingController(), n = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title:
                    Text(tr(input ? 'Kassaga kiritish' : 'Kassadan chiqarish')),
                content: SizedBox(
                    width: 450,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: a,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: tr('Summa'))),
                      const SizedBox(height: 12),
                      TextField(
                          controller: n,
                          decoration: InputDecoration(labelText: tr('Izoh')))
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('Bekor qilish'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Saqlash')))
                ]));
    if (ok == true) {
      try {
        await controller.repository.client.rpc('record_cash_movement', params: {
          'p_shift_id': s['id'],
          'p_kind': input ? 'DEPOSIT' : 'WITHDRAWAL',
          'p_amount': int.tryParse(a.text) ?? 0,
          'p_note': n.text
        });
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _close(BuildContext context, Map<String, dynamic> s,
      Map<String, dynamic> t) async {
    final a = TextEditingController(
        text: '${t['expected_cash'] ?? s['expected_cash'] ?? 0}');
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(tr('Smenani yopish')),
                content: TextField(
                    controller: a,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: tr('Haqiqiy naqd pul'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('Bekor qilish'))),
                  FilledButton(
                      style:
                          FilledButton.styleFrom(backgroundColor: VColors.red),
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Yopish')))
                ]));
    if (ok == true) {
      try {
        await controller.repository.client.rpc('close_cash_shift', params: {
          'p_shift_id': s['id'],
          'p_actual_cash': int.tryParse(a.text) ?? 0,
          'p_note': null
        });
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }
}

class _DayData {
  _DayData(this.report, this.shiftTotals);
  final Map<String, dynamic> report;
  final Map<String, dynamic>? shiftTotals;
}
