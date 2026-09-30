import 'package:flutter/material.dart';

import '../services/printer_service.dart';
import '../services/receipt_builder.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/receipt_preview.dart';

/// The "Yakunlash va to'lash" sheet — shown right after a session has been
/// finished, so the order it's reading is already closed and its totals are
/// final (time rounded, last round settled). Nothing here mutates the
/// session anymore, only the order: attach a customer, pick a method, pay.
Future<void> showSessionPaymentDialog(
  BuildContext context, {
  required ClubController controller,
  required String orderId,
  String? sessionId,
  String? resourceName,
  num? pricePerHour,
  String? familyLabel,
}) {
  return showDialog(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => _PaymentDialog(
      // The caller's own context — unlike `dialogContext`, it stays mounted
      // after this dialog pops itself, so it's what we use to reliably close
      // this sheet and then open the receipt preview on top of the page
      // underneath, instead of a context whose route may already be gone.
      callerContext: context,
      controller: controller,
      orderId: orderId,
      sessionId: sessionId,
      resourceName: resourceName,
      pricePerHour: pricePerHour,
      familyLabel: familyLabel,
    ),
  );
}

class _Data {
  _Data(this.order, this.rounds, this.methods, this.discounts, this.customers);
  final Map<String, dynamic> order;
  final List<Map<String, dynamic>> rounds;
  final List<Map<String, dynamic>> methods;
  final List<Map<String, dynamic>> discounts;
  final List<Map<String, dynamic>> customers;
}

class _PaymentDialog extends StatefulWidget {
  const _PaymentDialog({
    required this.callerContext,
    required this.controller,
    required this.orderId,
    required this.sessionId,
    required this.resourceName,
    this.pricePerHour,
    this.familyLabel,
  });

  final BuildContext callerContext;
  final ClubController controller;
  final String orderId;
  final String? sessionId;
  final String? resourceName;
  final num? pricePerHour;
  final String? familyLabel;

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  String? methodId;
  final amountCtrl = TextEditingController();
  bool paying = false;
  // Tracks whether the cashier has actually typed into the amount field --
  // as opposed to just it being non-empty, which `amountCtrl.clear()` calls
  // scattered at a few (but not all) mutation points relied on. A discount
  // or an added product changing the order's total without going through
  // one of those specific spots (e.g. attaching a customer) used to leave
  // the field showing a stale, too-high amount that no longer matched JAMI.
  bool _amountEdited = false;
  // Stored instead of called inline in build(): a FutureBuilder whose
  // `future` is created fresh on every build re-runs this whole five-call
  // chain and resets to the loading state on *any* rebuild -- not just
  // flicker, but a real risk of wiping whatever the cashier had already
  // typed into amountCtrl mid-payment. Only reassigned at the three points
  // below that actually need a fresh read.
  late Future<_Data> _future = _load();

  Future<_Data> _load() async {
    final repo = widget.controller.repository;
    final clubId = widget.controller.context!.clubId;
    final order = await repo.orderJson(widget.orderId);
    final rounds = widget.sessionId == null
        ? const <Map<String, dynamic>>[]
        : await repo.sessionRounds(widget.sessionId!);
    final methods = await repo.paymentMethods(clubId);
    final discounts = await repo.discounts(clubId);
    final customers = await repo.customers(clubId);
    return _Data(order, rounds, methods, discounts, customers);
  }

  @override
  void dispose() {
    amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Dialog(
        child: SizedBox(
          width: 520,
          child: FutureBuilder<_Data>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const SizedBox(height: 320, child: LoadingPane());
              }
              final data = snap.data!;
              final order = data.order;
              final total = (order['total_amount'] as num?)?.toInt() ?? 0;
              if (!_amountEdited) amountCtrl.text = '$total';
              // Default to cash — the common case — so the cashier doesn't
              // have to open the dropdown for every single sale.
              if (methodId == null && data.methods.isNotEmpty) {
                final cash = data.methods.firstWhere((m) => m['key'] == 'cash',
                    orElse: () => data.methods.first);
                methodId = '${cash['id']}';
              }
              final customerName = order['customer_name'] as String?;
              final items = ((order['order_items'] as List?) ?? [])
                  .cast<Map<String, dynamic>>()
                  .where((i) => i['kind'] == 'PRODUCT')
                  .toList();

              return Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                            widget.resourceName == null
                                ? 'To\'lov'
                                : 'To\'lov — ${widget.resourceName}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 20)),
                      ),
                      IconButton(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.close_rounded)),
                    ]),
                    const SizedBox(height: 4),
                    Row(children: [
                      Icon(Icons.person_outline_rounded,
                          size: 18, color: VColors.subtle),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(customerName ?? 'Mijozsiz',
                            style: TextStyle(
                                color: VColors.muted,
                                fontWeight: FontWeight.w700)),
                      ),
                      if (order['customer_id'] != null)
                        IconButton(
                          onPressed: () => _selectCustomer(null),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          tooltip: 'Mijozni olib tashlash',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(),
                          visualDensity: VisualDensity.compact,
                        ),
                    ]),
                    const SizedBox(height: 6),
                    Autocomplete<Map<String, dynamic>>(
                      displayStringForOption: (c) =>
                          '${c['full_name'] ?? c['phone'] ?? 'Mijoz'}',
                      optionsBuilder: (v) {
                        final q = v.text.trim().toLowerCase();
                        if (q.isEmpty) {
                          return const Iterable<Map<String, dynamic>>.empty();
                        }
                        final digits = q.replaceAll(RegExp(r'\D'), '');
                        return data.customers.where((c) {
                          final name = '${c['full_name'] ?? ''}'.toLowerCase();
                          final phone = '${c['phone'] ?? ''}';
                          if (name.contains(q)) return true;
                          if (digits.isNotEmpty &&
                              phone
                                  .replaceAll(RegExp(r'\D'), '')
                                  .contains(digits)) {
                            return true;
                          }
                          return false;
                        });
                      },
                      onSelected: (c) => _selectCustomer('${c['id']}'),
                      fieldViewBuilder:
                          (context, textCtrl, focusNode, onSubmitted) =>
                              TextField(
                        controller: textCtrl,
                        focusNode: focusNode,
                        style: const TextStyle(fontSize: 14),
                        decoration: InputDecoration(
                          isDense: true,
                          prefixIcon:
                              const Icon(Icons.search_rounded, size: 18),
                          hintText: 'Ism, telefon — yoki kartani skaner qiling',
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 12),
                        ),
                        onSubmitted: (v) {
                          final scanned = fixScannerLayout(v.trim());
                          if (scanned.toUpperCase().startsWith('CARD:')) {
                            final token =
                                scanned.substring(5).trim().toLowerCase();
                            final byToken = data.customers.where((c) {
                              return '${c['card_token'] ?? ''}'.toLowerCase() ==
                                  token;
                            }).toList();
                            if (byToken.isNotEmpty) {
                              _selectCustomer('${byToken.first['id']}');
                              textCtrl.clear();
                            }
                            return;
                          }
                          // Legacy card format kept for already-issued QR cards.
                          if (scanned.toUpperCase().startsWith('CUST:')) {
                            final id = scanned.substring(5).trim();
                            final byId = data.customers
                                .where((c) => '${c['id']}' == id)
                                .toList();
                            if (byId.isNotEmpty) {
                              _selectCustomer('${byId.first['id']}');
                              textCtrl.clear();
                            }
                            return;
                          }
                          final digits = scanned.replaceAll(RegExp(r'\D'), '');
                          if (digits.isEmpty) return;
                          final byPhone = data.customers.where((c) {
                            final phone = '${c['phone'] ?? ''}'
                                .replaceAll(RegExp(r'\D'), '');
                            return phone.isNotEmpty && phone == digits;
                          }).toList();
                          if (byPhone.length == 1) {
                            _selectCustomer('${byPhone.first['id']}');
                            textCtrl.clear();
                          }
                        },
                      ),
                      optionsViewBuilder: (context, onSelected, options) =>
                          Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          borderRadius: BorderRadius.circular(12),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                                maxHeight: 220, maxWidth: 472),
                            child: ListView(
                              shrinkWrap: true,
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              children: options
                                  .map((c) => ListTile(
                                        dense: true,
                                        leading: CircleAvatar(
                                          radius: 14,
                                          backgroundColor: VColors.greenSoft,
                                          child: Icon(
                                              Icons.person_outline_rounded,
                                              size: 15,
                                              color: VColors.green),
                                        ),
                                        title: Text(
                                            '${c['full_name'] ?? 'Mijoz'}'),
                                        subtitle: Text('${c['phone'] ?? ''}'),
                                        onTap: () => onSelected(c),
                                      ))
                                  .toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 260),
                      child: SingleChildScrollView(
                        child: Column(children: [
                          for (final r in data.rounds)
                            _line(
                                '${widget.resourceName} · раунд ${r['round_number']} (${_time(r['started_at'])}–${_time(r['ended_at'])})'
                                '${'${r['note'] ?? ''}'.trim().isEmpty ? '' : ' — ${r['note']}'}',
                                money(r['amount'])),
                          for (final i in items)
                            _line(
                                '${i['description']}${(i['quantity'] as num? ?? 1) > 1 ? ' × ${i['quantity']}' : ''}',
                                money(i['total_price'])),
                        ]),
                      ),
                    ),
                    const Divider(height: 28),
                    _line('Vaqt', money(order['time_amount']), muted: true),
                    _line('Tovarlar', money(order['items_amount']),
                        muted: true),
                    if (((order['discount_amount'] as num?) ?? 0) > 0)
                      _line('Chegirma', '-${money(order['discount_amount'])}',
                          muted: true),
                    const SizedBox(height: 8),
                    Row(children: [
                      TextButton.icon(
                        onPressed: data.discounts.isEmpty
                            ? null
                            : () => _chooseDiscount(context, data.discounts),
                        style: TextButton.styleFrom(
                          foregroundColor: VColors.green,
                          padding: EdgeInsets.zero,
                          minimumSize: const Size(0, 32),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.percent_rounded, size: 16),
                        label: const Text('Chegirma'),
                      ),
                      if (order['customer_id'] != null) ...[
                        const SizedBox(width: 14),
                        TextButton.icon(
                          onPressed:
                              ((order['customer_bonus_points'] as num?) ?? 0) <=
                                      0
                                  ? null
                                  : () => _redeemPoints(context, order),
                          style: TextButton.styleFrom(
                            foregroundColor: VColors.blue,
                            padding: EdgeInsets.zero,
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const Icon(Icons.toll_outlined, size: 16),
                          label: Text(
                              'Ball (${order['customer_bonus_points'] ?? 0})'),
                        ),
                      ],
                      const Spacer(),
                      const Text('JAMI',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 17)),
                      const SizedBox(width: 10),
                      Text(money(total),
                          style: TextStyle(
                              color: VColors.green,
                              fontWeight: FontWeight.w900,
                              fontSize: 24)),
                    ]),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue: methodId,
                      decoration:
                          const InputDecoration(labelText: 'To\'lov usuli'),
                      items: data.methods
                          .map((m) => DropdownMenuItem(
                                value: '${m['id']}',
                                child: Text('${m['name']}'),
                              ))
                          .toList(),
                      onChanged: (v) => setState(() => methodId = v),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: amountCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                          labelText: 'Summa', suffixText: 'so\'m'),
                      onChanged: (_) => _amountEdited = true,
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: (paying || methodId == null)
                            ? null
                            : () => _pay(context, total, data),
                        child: paying
                            ? const SizedBox.square(
                                dimension: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : Text(
                                'To\'lash — ${money(int.tryParse(amountCtrl.text) ?? total)}'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      );

  Widget _line(String label, String value, {bool muted = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(color: muted ? VColors.muted : null))),
          Text(value,
              style: TextStyle(
                  color: muted ? VColors.muted : null,
                  fontWeight: muted ? FontWeight.w500 : FontWeight.w700)),
        ]),
      );

  String _time(dynamic iso) {
    if (iso == null) return '';
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _chooseDiscount(
      BuildContext context, List<Map<String, dynamic>> discounts) async {
    final discount = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Chegirma'),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: discounts
                .map((d) => ListTile(
                      leading:
                          Icon(Icons.percent_rounded, color: VColors.green),
                      title: Text('${d['name']}'),
                      subtitle: d['applies_to'] == 'TIME'
                          ? const Text('faqat vaqtga')
                          : null,
                      trailing: Text(
                        d['kind'] == 'PERCENT'
                            ? '${d['value']}%'
                            : money(d['value']),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      onTap: () => Navigator.pop(context, d),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Bekor qilish')),
        ],
      ),
    );
    if (discount == null) return;
    try {
      await widget.controller.repository
          .applyDiscount(widget.orderId, discountId: '${discount['id']}');
      _amountEdited = false;
      setState(() => _future = _load());
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _redeemPoints(
      BuildContext context, Map<String, dynamic> order) async {
    final available = (order['customer_bonus_points'] as num?) ?? 0;
    final subtotal = ((order['items_amount'] as num?) ?? 0) +
        ((order['time_amount'] as num?) ?? 0);
    final maxPoints = available < subtotal ? available : subtotal;
    final ctrl = TextEditingController(text: '${maxPoints.toInt()}');
    final points = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Ballardan yechish'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mavjud: $available ball · 1 ball = 1 so\'m',
                style: TextStyle(color: VColors.muted)),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Yechiladigan ball'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Bekor qilish')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, int.tryParse(ctrl.text) ?? 0),
              child: const Text('Yechish')),
        ],
      ),
    );
    if (points == null || points <= 0) return;
    try {
      await widget.controller.repository.redeemPoints(widget.orderId, points);
      _amountEdited = false;
      setState(() => _future = _load());
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _selectCustomer(String? id) async {
    try {
      await widget.controller.repository.setOrderCustomer(widget.orderId, id);
      _amountEdited = false;
      setState(() => _future = _load());
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _pay(BuildContext context, int total, _Data data) async {
    // Hard re-entrancy guard: a rapid double-click can fire this handler
    // twice before the first `setState` even repaints the disabled button —
    // checking `paying` here (synchronously, before any `await`) is what
    // actually stops the second call, not just disabling the widget.
    if (paying) return;
    setState(() => paying = true);
    try {
      final amount = int.tryParse(amountCtrl.text) ?? total;
      final method = data.methods.firstWhere((m) => '${m['id']}' == methodId,
          orElse: () => const <String, dynamic>{});
      await widget.controller.repository
          .payOrder(widget.orderId, methodId!, amount);
      final receipt = await _buildReceipt(data, amount, method);
      // Close the payment sheet the instant the charge succeeds — before
      // showing anything else — so there is no window where a stale "To'lash"
      // button is still on screen and tappable, which was firing a second
      // `payOrder` on an already-completed order (ORDER_ALREADY_PAID).
      widget.controller.refresh();
      final caller = widget.callerContext;
      if (caller.mounted) {
        Navigator.of(caller).pop();
        showDone(caller, 'To\'landi');
      }
      if (receipt != null && caller.mounted) {
        await _handleReceipt(caller, receipt);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => paying = false);
    }
  }

  Future<_Receipt?> _buildReceipt(
      _Data data, int amount, Map<String, dynamic> method) async {
    try {
      final order = data.order;
      final items = ((order['order_items'] as List?) ?? [])
          .cast<Map<String, dynamic>>()
          .where((i) => i['kind'] == 'PRODUCT')
          .toList();
      final lines = [
        for (final r in data.rounds)
          ReceiptLine(
              '${widget.resourceName ?? 'Seans'} · raund ${r['round_number']}',
              (r['amount'] as num?)?.toInt() ?? 0,
              note: r['note'] as String?,
              kind: 'time',
              startedAt: DateTime.tryParse('${r['started_at']}'),
              endedAt: DateTime.tryParse('${r['ended_at']}')),
        for (final i in items)
          ReceiptLine(
              '${i['description']}', (i['total_price'] as num?)?.toInt() ?? 0,
              quantity: i['quantity'] as num?,
              cost: (i['unit_cost'] as num?) == null
                  ? null
                  : (((i['unit_cost'] as num).toDouble() *
                          ((i['quantity'] as num?)?.toDouble() ?? 1))
                      .round())),
      ];
      final discount = (order['discount_amount'] as num?)?.toInt() ?? 0;
      final subtotal = ((order['time_amount'] as num?)?.toInt() ?? 0) +
          ((order['items_amount'] as num?)?.toInt() ?? 0);
      final sessionStartedAt = data.rounds.isEmpty
          ? null
          : DateTime.tryParse('${data.rounds.first['started_at']}');
      final sessionEndedAt = data.rounds.isEmpty
          ? null
          : DateTime.tryParse('${data.rounds.last['ended_at']}');
      return _Receipt(
        receiptNumber: (order['order_number'] as num?)?.toInt(),
        date: DateTime.now(),
        lines: lines,
        subtotal: subtotal,
        discount: discount,
        total: amount,
        paymentMethodName: '${method['name'] ?? ''}',
        sessionStartedAt: sessionStartedAt,
        sessionEndedAt: sessionEndedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Shows the receipt itself with "Chop etish"/"Yopish" right on it,
  /// instead of a separate yes/no prompt with no receipt visible -- printing
  /// used to also fire automatically the instant a printer was configured,
  /// with no way for the cashier to skip it for a given sale.
  Future<void> _handleReceipt(BuildContext context, _Receipt receipt) async {
    if (!context.mounted) return;
    await _showReceiptPreview(context, receipt);
  }

  Future<void> _showReceiptPreview(
      BuildContext context, _Receipt receipt) async {
    final club = widget.controller.context!.club;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(receipt.receiptNumber != null
            ? 'Chek №${receipt.receiptNumber}'
            : 'Chek'),
        content: Container(
          width: 420,
          color: VColors.field,
          padding: const EdgeInsets.all(20),
          child: Center(
            child: SingleChildScrollView(
              child: ReceiptPreview(
                club: club,
                cashierName: widget.controller.context!.userName,
                resourceName: widget.resourceName,
                pricePerHour: widget.pricePerHour,
                familyLabel: widget.familyLabel,
                receiptNumber: receipt.receiptNumber,
                date: receipt.date,
                lines: receipt.lines,
                subtotal: receipt.subtotal,
                discount: receipt.discount,
                total: receipt.total,
                paymentMethodName: receipt.paymentMethodName,
                sessionStartedAt: receipt.sessionStartedAt,
                sessionEndedAt: receipt.sessionEndedAt,
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Yopish')),
          FilledButton.icon(
            onPressed: () async {
              try {
                final config = await PrinterConfig.load();
                if (!config.isConfigured) {
                  if (dialogContext.mounted) {
                    showError(dialogContext, 'Printer sozlanmagan');
                  }
                  return;
                }
                final bytes = buildOrderReceipt(
                  club: club,
                  cashierName: widget.controller.context!.userName,
                  resourceName: widget.resourceName,
                  pricePerHour: widget.pricePerHour,
                  familyLabel: widget.familyLabel,
                  receiptNumber: receipt.receiptNumber ?? 0,
                  date: receipt.date,
                  items: receipt.lines,
                  subtotal: receipt.subtotal,
                  discount: receipt.discount,
                  total: receipt.total,
                  paymentMethodName: receipt.paymentMethodName,
                  sessionStartedAt: receipt.sessionStartedAt,
                  sessionEndedAt: receipt.sessionEndedAt,
                  printCost: club['receipt_print_cost'] == true,
                );
                await PrinterService.print(config, bytes);
              } catch (e) {
                if (dialogContext.mounted) showError(dialogContext, e);
              }
            },
            icon: const Icon(Icons.print_outlined),
            label: const Text('Chop etish'),
          ),
        ],
      ),
    );
  }
}

class _Receipt {
  const _Receipt({
    required this.receiptNumber,
    required this.date,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethodName,
    this.sessionStartedAt,
    this.sessionEndedAt,
  });
  final int? receiptNumber;
  final DateTime date;
  final List<ReceiptLine> lines;
  final int subtotal;
  final int discount;
  final int total;
  final String paymentMethodName;
  final DateTime? sessionStartedAt;
  final DateTime? sessionEndedAt;
}
