import 'package:flutter/material.dart';

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
                  if (current == null) {
                    return Center(
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                      EmptyState(
                          icon: Icons.point_of_sale_outlined,
                          title: tr('Smena yopiq'),
                          subtitle:
                              tr('Savdoni boshlash uchun smenani oching')),
                      const SizedBox(height: 20),
                      FilledButton.icon(
                          onPressed: () => _open(context),
                          icon: const Icon(Icons.lock_open_rounded),
                          label: Text(tr('Smenani ochish')))
                    ]));
                  }
                  return FutureBuilder<Map<String, dynamic>>(
                      future: controller.repository.client.rpc('shift_totals',
                          params: {'p_shift_id': current['id']}).then(rowMap),
                      builder: (context, snap) {
                        final t = snap.data ??
                            Map<String, dynamic>.from(
                                current['totals'] as Map? ?? {});
                        final isCashier = controller.context!.isCashier;
                        return ListView(children: [
                          VCard(
                              child: Column(children: [
                            _row(tr('Kassir'), controller.context!.userName,
                                bold: true),
                            _row(tr('Ochilgan'),
                                shortDate(current['opened_at'])),
                            _row(tr('Smena boshidagi summa'),
                                money(current['opening_cash']))
                          ])),
                          const SizedBox(height: 20),
                          if (!isCashier) ...[
                            VCard(
                                child: Column(children: [
                              _row(tr('Buyurtmalar'),
                                  '${t['orders_count'] ?? 0}'),
                              _row('Uzcard', money(t['card'] ?? t['uzcard'])),
                              _row('Долг', money(t['debt'])),
                              _row('Перевод', money(t['transfer'])),
                              _row('Наличные', money(t['cash'])),
                              _row(tr('Tushum'),
                                  money(t['revenue'] ?? t['total']),
                                  bold: true),
                              _row(tr('Tannarx'), money(t['cost'])),
                              _row(tr('Foyda'), money(t['profit']), bold: true),
                              _row(tr('Xarajatlar'), money(t['expenses'])),
                              _row(tr('Sof foyda'), money(t['net_profit']),
                                  bold: true),
                              _row(
                                  tr('Kassada bo\'lishi kerak'),
                                  money(t['expected_cash'] ??
                                      current['expected_cash']),
                                  bold: true)
                            ])),
                            const SizedBox(height: 20),
                          ],
                          // Depositing/withdrawing cash outside a sale is an
                          // easy way to quietly move money in or out of the
                          // drawer -- only owner/admin get it now, same as
                          // the shift totals and X-report right above.
                          if (!isCashier) ...[
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
                          ],
                          if (!isCashier) ...[
                            SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                    onPressed: () =>
                                        _printX(context, current, t),
                                    icon: const Icon(Icons.print_outlined),
                                    label: Text(tr('X-hisobotni chop etish')))),
                            const SizedBox(height: 14),
                          ],
                          SizedBox(
                              width: double.infinity,
                              child: FilledButton.icon(
                                  style: FilledButton.styleFrom(
                                      backgroundColor: VColors.red),
                                  onPressed: () => _close(context, current, t),
                                  icon: const Icon(Icons.lock_outline_rounded),
                                  label: Text(tr('Smenani yopish'))))
                        ]);
                      });
                }))
      ]));
  Widget _row(String a, String b, {bool bold = false}) => Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: VColors.line))),
      child: InfoRow(a, b, bold: bold));
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
