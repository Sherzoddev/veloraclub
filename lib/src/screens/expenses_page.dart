import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class ExpensesPage extends StatefulWidget {
  const ExpensesPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<ExpensesPage> createState() => _ExpensesPageState();
}

class _ExpensesPageState extends State<ExpensesPage> {
  String category = 'ALL';

  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.all(30),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        PageHeader(title: 'Xarajatlar', actions: [
          FilledButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Xarajat qo\'shish'))
        ]),
        const SizedBox(height: 8),
        // AsyncPane, not a raw FutureBuilder: selecting a category chip
        // below calls setState on this whole page, which used to recreate
        // this FutureBuilder's future and reset it to no-data -- the total
        // line and the chip row itself would blank out and flash back in on
        // every filter click. AsyncPane keeps showing the last good data
        // while a new future resolves instead of dropping back to empty.
        AsyncPane<List<Map<String, dynamic>>>(
            future: widget.controller.repository
                .expenses(widget.controller.context!.clubId),
            builder: (_, rows) => Text(
                'Jami (oxirgi ${rows.length} ta): ${money(rows.fold<num>(0, (a, b) => a + (b['amount'] as num? ?? 0)))}',
                style: TextStyle(color: VColors.muted))),
        const SizedBox(height: 16),
        AsyncPane<List<Map<String, dynamic>>>(
          future: widget.controller.repository
              .expenseCategories(widget.controller.context!.clubId),
          builder: (context, cats) {
            return Wrap(spacing: 8, runSpacing: 8, children: [
              for (final c in cats)
                ChoiceChip(
                  label: Text('${c['name']}'),
                  selected: category == '${c['id']}',
                  onSelected: (_) =>
                      setState(() => category = category == '${c['id']}' ? 'ALL' : '${c['id']}'),
                ),
              ActionChip(
                avatar: const Icon(Icons.add, size: 16),
                label: const Text('Toifa'),
                onPressed: () => _addCategory(context),
              ),
            ]);
          },
        ),
        const SizedBox(height: 18),
        Expanded(
            child: AsyncPane<List<Map<String, dynamic>>>(
                future: widget.controller.repository
                    .expenses(widget.controller.context!.clubId),
                builder: (context, allRows) {
                  final rows = category == 'ALL'
                      ? allRows
                      : allRows
                          .where((e) => '${e['category_id']}' == category)
                          .toList();
                  if (rows.isEmpty) {
                    return const EmptyState(
                        icon: Icons.request_quote_outlined,
                        title: 'Xarajat topilmadi',
                        subtitle: 'Yangi xarajat qo\'shing');
                  }
                  return ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final e = rows[i];
                      final cat = e['expense_categories'];
                      final reversed = e['status'] == 'REVERSED';
                      final title = cat is Map ? '${cat['name']}' : 'Xarajat';
                      final subParts = [
                        shortDate(e['spent_at']),
                        if (e['profiles']?['full_name'] != null)
                          '${e['profiles']['full_name']}',
                        if ('${e['comment'] ?? ''}'.trim().isNotEmpty)
                          '${e['comment']}',
                      ];
                      return Opacity(
                        opacity: reversed ? .55 : 1,
                        child: Card(
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                                color: cat is Map && cat['color'] != null
                                    ? Color(int.parse(
                                        '${cat['color']}'
                                            .replaceFirst('#', 'FF'),
                                        radix: 16))
                                    : VColors.line,
                                width: cat is Map && cat['color'] != null
                                    ? 2
                                    : 1),
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            child: Row(children: [
                              Expanded(
                                  child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(title,
                                            style: TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 16,
                                                decoration: reversed
                                                    ? TextDecoration
                                                        .lineThrough
                                                    : null)),
                                        const SizedBox(height: 3),
                                        Text(subParts.join(' · '),
                                            style: TextStyle(
                                                color: VColors.subtle,
                                                fontSize: 12.5)),
                                        if (reversed)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                                top: 3),
                                            child: Text('Bekor qilingan',
                                                style: TextStyle(
                                                    color: VColors.red,
                                                    fontSize: 12,
                                                    fontWeight:
                                                        FontWeight.w700)),
                                          ),
                                      ])),
                              const SizedBox(width: 14),
                              Text(
                                  '${(e['amount'] as num? ?? 0) < 0 ? '+' : '-'}${money((e['amount'] as num? ?? 0).abs())}',
                                  style: TextStyle(
                                      // Reversal rows are also flagged REVERSED (so both
                                      // the original and its negative counter-entry read
                                      // as "cancelled" here) -- pre-existing behavior,
                                      // not something this visual pass changes.
                                      color: VColors.red,
                                      fontWeight: FontWeight.w800,
                                      fontSize: 16)),
                              if (!reversed) ...[
                                const SizedBox(width: 12),
                                OutlinedButton(
                                    onPressed: () => _reverse(context, e),
                                    style: OutlinedButton.styleFrom(
                                        minimumSize: const Size(0, 34),
                                        foregroundColor: VColors.red,
                                        side: BorderSide(
                                            color: VColors.red
                                                .withValues(alpha: .4))),
                                    child: const Text('Bekor qilish')),
                              ],
                            ]),
                          ),
                        ),
                      );
                    },
                  );
                })),
      ]));

  Future<void> _addCategory(BuildContext context) async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Yangi toifa'),
        content: TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Nomi')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Bekor qilish')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Saqlash')),
        ],
      ),
    );
    if (ok != true || name.text.trim().isEmpty) return;
    await widget.controller.repository.client.from('expense_categories').insert({
      'club_id': widget.controller.context!.clubId,
      'name': name.text.trim(),
      'active': true,
    });
    widget.controller.refresh();
    setState(() {});
  }

  Future<void> _add(BuildContext context) async {
    final controller = widget.controller;
    final cats = await controller.repository
        .expenseCategories(controller.context!.clubId);
    final methods =
        await controller.repository.paymentMethods(controller.context!.clubId);
    final shifts =
        await controller.repository.shifts(controller.context!.clubId);
    if (!context.mounted) return;
    String? cat = cats.firstOrNull?['id']?.toString();
    String? method;
    final amount = TextEditingController(), comment = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
                    title: const Text('Yangi xarajat'),
                    content: SizedBox(
                        width: 460,
                        child:
                            Column(mainAxisSize: MainAxisSize.min, children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Text('Toifa',
                                style: TextStyle(
                                    color: VColors.subtle, fontSize: 12)),
                          ),
                          const SizedBox(height: 6),
                          SizedBox(
                            height: 38,
                            child: ListView(
                              scrollDirection: Axis.horizontal,
                              children: [
                                ChoiceChip(
                                    label: const Text('Toifasiz'),
                                    selected: cat == null,
                                    onSelected: (_) =>
                                        setState(() => cat = null)),
                                for (final e in cats)
                                  Padding(
                                    padding: const EdgeInsets.only(left: 8),
                                    child: ChoiceChip(
                                        label: Text('${e['name']}'),
                                        selected: cat == '${e['id']}',
                                        onSelected: (_) => setState(
                                            () => cat = '${e['id']}')),
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                              controller: amount,
                              autofocus: true,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                  labelText: 'Summa (so\'m)')),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String?>(
                              initialValue: method,
                              decoration: const InputDecoration(
                                  labelText: 'Pul qayerdan'),
                              items: [
                                const DropdownMenuItem<String?>(
                                    value: null,
                                    child:
                                        Text('Kassadan naqd pul (standart)')),
                                ...methods.map((e) => DropdownMenuItem<String?>(
                                    value: '${e['id']}',
                                    child: Text('${e['name']}'))),
                              ],
                              onChanged: (v) => setState(() => method = v)),
                          const SizedBox(height: 10),
                          TextField(
                              controller: comment,
                              decoration:
                                  const InputDecoration(hintText: 'Izoh'))
                        ])),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Bekor qilish')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Saqlash'))
                    ])));
    if (ok == true) {
      // Strip anything but digits so thousand-separator formatting (spaces,
      // dots) still parses — a blank/unparseable field used to fall back to
      // 0, which the database's `amount > 0` check rejects outright.
      final parsedAmount =
          int.tryParse(amount.text.replaceAll(RegExp(r'[^0-9]'), ''));
      if (parsedAmount == null || parsedAmount <= 0) {
        if (context.mounted) {
          showError(context, Exception('Summani kiriting'));
        }
        return;
      }
      try {
        await controller.repository.client.from('expenses').insert({
          'club_id': controller.context!.clubId,
          'category_id': cat,
          'payment_method_id': method,
          'cash_shift_id':
              shifts.where((e) => e['status'] == 'OPEN').firstOrNull?['id'],
          'amount': parsedAmount,
          'comment': comment.text,
          'spent_at': DateTime.now().toUtc().toIso8601String(),
          'created_by': controller.repository.user!.id
        });
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _reverse(BuildContext context, Map<String, dynamic> e) async {
    final controller = widget.controller;
    try {
      await controller.repository.client.from('expenses').insert({
        'club_id': controller.context!.clubId,
        'category_id': e['category_id'],
        'cash_shift_id': e['cash_shift_id'],
        'payment_method_id': e['payment_method_id'],
        'amount': -(e['amount'] as num),
        'comment': 'Qaytarish: ${e['comment'] ?? ''}',
        'spent_at': DateTime.now().toUtc().toIso8601String(),
        'created_by': controller.repository.user!.id,
        'reverses_expense_id': e['id'],
        'status': 'REVERSED'
      });
      await controller.repository.client
          .from('expenses')
          .update({'status': 'REVERSED'}).eq('id', e['id']);
      controller.refresh();
    } catch (err) {
      if (context.mounted) showError(context, err);
    }
  }
}
