import 'package:flutter/material.dart';

import '../i18n.dart';
import '../services/printer_service.dart';
import '../services/receipt_builder.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/receipt_preview.dart';

class OrdersPage extends StatefulWidget {
  const OrdersPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<OrdersPage> createState() => _OrdersPageState();
}

class _OrdersPageState extends State<OrdersPage> {
  String query = '';

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          children: [
            PageHeader(
              title: tr('Cheklar'),
              subtitle: tr('Yopilgan va ochiq cheklar'),
              actions: [
                IconButton(
                  onPressed: widget.controller.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SearchBox(
              hint: tr('Chek raqami, stol yoki mijoz'),
              onChanged: (value) => setState(() => query = value.toLowerCase()),
            ),
            const SizedBox(height: 18),
            Expanded(
              child: AsyncPane<List<Map<String, dynamic>>>(
                future: widget.controller.repository
                    .orders(widget.controller.context!.clubId),
                builder: (context, rows) {
                  final filtered = rows.where((row) {
                    final customer = row['customers'];
                    final customerName =
                        customer is Map ? customer['full_name'] : '';
                    return '${row['order_number']} $customerName ${row['game_sessions']}'
                        .toLowerCase()
                        .contains(query);
                  }).toList();
                  return ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final row = filtered[index];
                      final session = row['game_sessions'];
                      final cancelled = row['status'] == 'CANCELLED';
                      final customer = row['customers'];
                      final opener = row['opener'];
                      var place = tr('Bar');
                      if (session is Map && session['resources'] is Map) {
                        place = '${session['resources']['name']}';
                      }
                      final title = row['order_number'] != null
                          ? '№${row['order_number']} · ${shortDate(row['created_at'])}'
                          : '${tr('Ochiq')} · ${shortDate(row['created_at'])}';
                      final subParts = [
                        if (opener is Map && opener['full_name'] != null)
                          '${opener['full_name']}',
                        place,
                        if (customer is Map && customer['full_name'] != null)
                          '${customer['full_name']}',
                      ];
                      return Opacity(
                        opacity: cancelled ? .55 : 1,
                        child: Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: VColors.line),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _showReceipt(row),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 16, vertical: 13),
                              child: Row(children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(title,
                                          style: TextStyle(
                                              fontWeight: FontWeight.w800,
                                              fontSize: 15.5,
                                              decoration: cancelled
                                                  ? TextDecoration.lineThrough
                                                  : null)),
                                      const SizedBox(height: 3),
                                      Text(subParts.join(' · '),
                                          style: TextStyle(
                                              color: VColors.subtle,
                                              fontSize: 12.5)),
                                      if (cancelled)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 3),
                                          child: Text(tr('Bekor qilingan'),
                                              style: TextStyle(
                                                  color: VColors.red,
                                                  fontSize: 12,
                                                  fontWeight:
                                                      FontWeight.w700)),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(money(row['total_amount']),
                                    style: const TextStyle(
                                        fontWeight: FontWeight.w800,
                                        fontSize: 16)),
                                const SizedBox(width: 10),
                                Icon(Icons.print_outlined,
                                    size: 18, color: VColors.subtle),
                              ]),
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );

  Future<void> _showReceipt(Map<String, dynamic> order) async {
    final repo = widget.controller.repository;
    final items = rowList(await repo.client
        .from('order_items')
        .select()
        .eq('order_id', order['id'])
        .order('created_at'));
    final payments = rowList(await repo.client
        .from('payments')
        .select('amount, payment_methods(name)')
        .eq('order_id', order['id']));
    final rounds = order['session_id'] == null
        ? const <Map<String, dynamic>>[]
        : await repo.sessionRounds('${order['session_id']}');
    final sessionRowRaw = order['session_id'] == null
        ? null
        : await repo.client
            .from('game_sessions')
            .select('tariff_snapshot, resources(resource_types(family))')
            .eq('id', '${order['session_id']}')
            .maybeSingle();
    final sessionRow =
        sessionRowRaw == null ? null : Map<String, dynamic>.from(sessionRowRaw);
    final pricePerHour =
        (sessionRow?['tariff_snapshot']?['price_per_hour'] as num?);
    final resourceTypes = sessionRow?['resources'] is Map
        ? sessionRow!['resources']['resource_types']
        : null;
    final familyLabel = resourceTypes is Map
        ? (resourceTypes['family'] == 'BILLIARD'
            ? tr('Bilyard')
            : resourceTypes['family'] == 'PLAYSTATION'
                ? 'PlayStation'
                : null)
        : null;
    if (!mounted) return;
    final club = widget.controller.context!.club;
    final title = order['order_number'] != null
        ? '${tr('Chek')} №${order['order_number']}'
        : tr('Chek (ochiq)');
    final session = order['game_sessions'];
    final resourceName = session is Map && session['resources'] is Map
        ? '${session['resources']['name']}'
        : null;
    final opener = order['opener'];
    final cashierName =
        opener is Map ? '${opener['full_name'] ?? ''}' : '';
    final paymentMethodName = payments.isEmpty
        ? ''
        : payments
            .map((p) => '${(p['payment_methods'] as Map?)?['name'] ?? ''}')
            .where((n) => n.isNotEmpty)
            .join(', ');
    final lines = [
      for (final r in rounds)
        ReceiptLine('${resourceName ?? tr('Seans')} · ${tr('raund')} ${r['round_number']}',
            (r['amount'] as num?)?.toInt() ?? 0,
            note: r['note'] as String?,
            kind: 'time',
            startedAt: DateTime.tryParse('${r['started_at']}'),
            endedAt: DateTime.tryParse('${r['ended_at']}')),
      for (final item in items.where((i) => i['kind'] == 'PRODUCT'))
        ReceiptLine('${item['description']}',
            (item['total_price'] as num?)?.toInt() ?? 0,
            quantity: item['quantity'] as num?,
            cost: (item['unit_cost'] as num?) == null
                ? null
                : (((item['unit_cost'] as num).toDouble() *
                        ((item['quantity'] as num?)?.toDouble() ?? 1))
                    .round())),
    ];
    final subtotal = (((order['time_amount'] as num?) ?? 0) +
            ((order['items_amount'] as num?) ?? 0))
        .toInt();
    final discount = (order['discount_amount'] as num?)?.toInt() ?? 0;
    final total = (order['total_amount'] as num?)?.toInt() ?? 0;
    final sessionStartedAt = rounds.isEmpty
        ? null
        : DateTime.tryParse('${rounds.first['started_at']}');
    final sessionEndedAt = rounds.isEmpty
        ? null
        : DateTime.tryParse('${rounds.last['ended_at']}');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Container(
          width: 550,
          height: 650,
          color: VColors.field,
          padding: const EdgeInsets.all(20),
          child: Center(
            child: SingleChildScrollView(
              child: ReceiptPreview(
                club: club,
                cashierName: cashierName,
                resourceName: resourceName,
                pricePerHour: pricePerHour,
                familyLabel: familyLabel,
                receiptNumber: order['order_number'] as int?,
                date: DateTime.tryParse('${order['created_at']}') ??
                    DateTime.now(),
                lines: lines,
                subtotal: subtotal,
                discount: discount,
                total: total,
                paymentMethodName: paymentMethodName,
                sessionStartedAt: sessionStartedAt,
                sessionEndedAt: sessionEndedAt,
              ),
            ),
          ),
        ),
        actions: [
          if (order['status'] == 'OPEN')
            TextButton(
              onPressed: () => _cancelOrder(dialogContext, order, items),
              style: TextButton.styleFrom(foregroundColor: VColors.red),
              child: Text(tr('Bekor qilish')),
            ),
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(tr('Yopish'))),
          FilledButton.icon(
              onPressed: () => _printReceipt(
                  order,
                  lines,
                  resourceName,
                  cashierName,
                  paymentMethodName,
                  sessionStartedAt,
                  sessionEndedAt,
                  pricePerHour,
                  familyLabel),
              icon: const Icon(Icons.print_outlined),
              label: Text(tr('Chop etish'))),
        ],
      ),
    );
  }

  Future<void> _cancelOrder(BuildContext dialogContext,
      Map<String, dynamic> order, List<Map<String, dynamic>> items) async {
    final confirmed = await showDialog<bool>(
      context: dialogContext,
      builder: (c) => AlertDialog(
        title: Text(tr('Buyurtmani bekor qilish')),
        content: Text(tr(
            'Buyurtma bekor qilinadi, tovarlar ombor qoldig\'iga qaytariladi. Bu amalni qaytarib bo\'lmaydi.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('Yo\'q'))),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VColors.red),
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('Bekor qilish'))),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final repo = widget.controller.repository;
      for (final item in items) {
        await repo.removeOrderItem('${item['id']}');
      }
      await repo.client
          .from('orders')
          .update({'status': 'CANCELLED'}).eq('id', order['id']);
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      widget.controller.refresh();
      if (mounted) showDone(context, tr('Buyurtma bekor qilindi'));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _printReceipt(
      Map<String, dynamic> order,
      List<ReceiptLine> lines,
      String? resourceName,
      String cashierName,
      String paymentMethodName,
      DateTime? sessionStartedAt,
      DateTime? sessionEndedAt,
      num? pricePerHour,
      String? familyLabel) async {
    try {
      final config = await PrinterConfig.load();
      if (!config.isConfigured) {
        if (mounted) {
          showError(context, tr('Printer sozlanmagan — Sozlamalar → Chek'));
        }
        return;
      }
      final bytes = buildOrderReceipt(
        club: widget.controller.context!.club,
        cashierName: cashierName.isEmpty
            ? widget.controller.context!.userName
            : cashierName,
        resourceName: resourceName,
        pricePerHour: pricePerHour,
        familyLabel: familyLabel,
        receiptNumber: (order['order_number'] as num?)?.toInt() ?? 0,
        date: DateTime.tryParse('${order['created_at']}') ?? DateTime.now(),
        items: lines,
        subtotal: (((order['time_amount'] as num?) ?? 0) +
                ((order['items_amount'] as num?) ?? 0))
            .toInt(),
        discount: (order['discount_amount'] as num?)?.toInt() ?? 0,
        total: (order['total_amount'] as num?)?.toInt() ?? 0,
        paymentMethodName: paymentMethodName,
        sessionStartedAt: sessionStartedAt,
        sessionEndedAt: sessionEndedAt,
        printCost: widget.controller.context!.club['receipt_print_cost'] ==
            true,
      );
      await PrinterService.print(config, bytes);
      if (mounted) showDone(context, tr('Chek chop etildi'));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
