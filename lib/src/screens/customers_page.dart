import 'package:flutter/material.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class CustomersPage extends StatefulWidget {
  const CustomersPage({super.key, required this.controller});
  final ClubController controller;
  @override
  State<CustomersPage> createState() => _CustomersPageState();
}

class _CustomersPageState extends State<CustomersPage> {
  String query = '';
  @override
  Widget build(BuildContext context) => Padding(
      padding: pagePadding(context),
      child: Column(children: [
        PageHeader(
            title: tr('Mijozlar'),
            subtitle: tr('Klub mijozlari va sodiqlik dasturi'),
            actions: [
              OutlinedButton.icon(
                  onPressed: () => _loyalty(context),
                  icon: const Icon(Icons.loyalty_outlined),
                  label: Text(tr('Sodiqlik'))),
              FilledButton.icon(
                  onPressed: () => _create(context),
                  icon: const Icon(Icons.person_add_alt_1_rounded),
                  label: Text(tr('Yangi mijoz')))
            ]),
        const SizedBox(height: 20),
        SearchBox(
            hint: tr('Ism, telefon — yoki mijoz kartasini skaner qiling'),
            onChanged: (v) => setState(() => query = v.toLowerCase())),
        const SizedBox(height: 18),
        Expanded(
            child: AsyncPane<List<Map<String, dynamic>>>(
                future: widget.controller.repository
                    .customers(widget.controller.context!.clubId),
                builder: (context, rows) {
                  final filtered = rows
                      .where((c) => '${c['full_name']} ${c['phone']}'
                          .toLowerCase()
                          .contains(query))
                      .toList();
                  return ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final tier = c['loyalty_tiers'];
                        final stats = [
                          Text(money(c['total_spent']),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w900)),
                          Text(
                              '${c['visits_count']} ${tr('ta tashrif')} · ${c['bonus_points']} ${tr('ball')}',
                              style: TextStyle(
                                  color: VColors.subtle, fontSize: 13))
                        ];
                        final compact = isCompactWidth(context);
                        return InkWell(
                            onTap: () => _details(context, c),
                            child: Padding(
                                padding: EdgeInsets.symmetric(
                                    horizontal: compact ? 8 : 18, vertical: 12),
                                child: Row(children: [
                                  CircleAvatar(
                                      radius: compact ? 22 : 26,
                                      backgroundColor: VColors.green,
                                      child: const Icon(
                                          Icons.person_outline_rounded,
                                          color: Colors.white)),
                                  const SizedBox(width: 14),
                                  Expanded(
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                        Text('${c['full_name'] ?? tr('Mijoz')}',
                                            style: const TextStyle(
                                                fontWeight: FontWeight.w700,
                                                fontSize: 16)),
                                        const SizedBox(height: 2),
                                        Text(
                                            '${c['phone'] ?? ''} · ${tier is Map ? tier['name'] : 'Новичок'}${c['discount_percent'] != 0 ? ' · ${tr('chegirma')} ${c['discount_percent']}%' : ''}',
                                            style: TextStyle(
                                                color: VColors.muted)),
                                        if (compact) ...[
                                          const SizedBox(height: 4),
                                          Wrap(
                                              spacing: 10,
                                              crossAxisAlignment:
                                                  WrapCrossAlignment.center,
                                              children: stats),
                                        ]
                                      ])),
                                  if (!compact) ...[
                                    const SizedBox(width: 14),
                                    Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.end,
                                        children: stats),
                                  ]
                                ])));
                      });
                }))
      ]));

  Future<void> _create(BuildContext context) async {
    final name = TextEditingController(), phone = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(tr('Yangi mijoz')),
                content: SizedBox(
                    width: 480,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          decoration: InputDecoration(labelText: tr('Ismi'))),
                      const SizedBox(height: 12),
                      TextField(
                          controller: phone,
                          decoration: InputDecoration(labelText: tr('Telefon')))
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
        await widget.controller.repository.client.from('customers').insert({
          'club_id': widget.controller.context!.clubId,
          'full_name': name.text.trim(),
          'phone': phone.text.trim()
        });
        widget.controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _details(BuildContext context, Map<String, dynamic> c) async {
    final tiers = rowList(await widget.controller.repository.client
        .from('loyalty_tiers')
        .select()
        .eq('club_id', widget.controller.context!.clubId)
        .order('sort_order', ascending: true));
    if (!context.mounted) return;
    await showDialog(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text('${c['full_name'] ?? tr('Mijoz')}'),
                content: SizedBox(
                    width: 500,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if ('${c['phone'] ?? ''}'.isNotEmpty)
                        Align(
                            alignment: Alignment.centerLeft,
                            child: Text('${c['phone']}',
                                style: TextStyle(color: VColors.muted))),
                      const SizedBox(height: 10),
                      _TierProgress(customer: c, tiers: tiers),
                      const SizedBox(height: 6),
                      _Info(tr('Balans'), money(c['balance'])),
                      _Info(
                          tr('Bonuslar'), '${c['bonus_points']} ${tr('ball')}'),
                      _Info(tr('Chegirma'), '${c['discount_percent']}%'),
                      _Info(tr('Qarz'), money(c['debt_amount'])),
                      _Info(tr('Jami sarflangan'), money(c['total_spent'])),
                      _Info(tr('Tashriflar'), '${c['visits_count']}'),
                      const Divider(),
                      // Cashiers ring up sales but must not be able to hand
                      // themselves or a friend bonus points/discounts, or
                      // dig through a customer's purchase history — that's
                      // owner/admin territory, especially given bonus
                      // farming is exactly what app_check_bonus_farming now
                      // watches for on the server side.
                      if (!(widget.controller.context?.isCashier ?? false))
                        Wrap(spacing: 10, runSpacing: 10, children: [
                          OutlinedButton.icon(
                              onPressed: () => _adjustPoints(context, c),
                              icon: const Icon(Icons.loyalty_outlined),
                              label: Text(tr('Bonuslar'))),
                          OutlinedButton.icon(
                              onPressed: () => _discount(context, c),
                              icon: const Icon(Icons.percent_rounded),
                              label: Text(tr('Chegirma'))),
                          OutlinedButton.icon(
                              onPressed: () => _orderHistory(context, c),
                              icon: const Icon(Icons.history_rounded),
                              label: Text(tr('Buyurtmalar tarixi')))
                        ])
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: Text(tr('Yopish')))
                ]));
  }

  Future<void> _orderHistory(
      BuildContext context, Map<String, dynamic> c) async {
    final orders = rowList(await widget.controller.repository.client
        .from('orders')
        .select('*, game_sessions!orders_session_id_fkey(resources(name))')
        .eq('customer_id', c['id'])
        .eq('status', 'COMPLETED')
        .order('created_at', ascending: false)
        .limit(50));
    if (!context.mounted) return;
    await showDialog(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(
                  '${c['full_name'] ?? tr('Mijoz')} · ${tr('buyurtmalar')}'),
              content: SizedBox(
                width: 480,
                height: 480,
                child: orders.isEmpty
                    ? Center(
                        child: Text(tr('Buyurtmalar yo\'q'),
                            style: TextStyle(color: VColors.subtle)))
                    : ListView.separated(
                        itemCount: orders.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final o = orders[i];
                          final session = o['game_sessions'];
                          final resource =
                              session is Map ? session['resources'] : null;
                          final title = resource is Map
                              ? '${resource['name']}'
                              : tr('Sotuv');
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(
                                o['order_number'] != null
                                    ? '${tr('Chek')} №${o['order_number']} · $title'
                                    : title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w700)),
                            subtitle: Text(shortDate(o['created_at'])),
                            trailing: Text(money(o['total_amount']),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900)),
                          );
                        },
                      ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(tr('Yopish')))
              ],
            ));
  }

  Future<void> _adjustPoints(
      BuildContext context, Map<String, dynamic> c) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(tr('Bonuslarni o\'zgartirish')),
                content: TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    decoration:
                        InputDecoration(labelText: tr('Miqdor (+ yoki -)'))),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('Bekor qilish'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Saqlash')))
                ]));
    if (ok == true) {
      await widget.controller.repository.client
          .rpc('customer_adjust_points', params: {
        'p_customer_id': c['id'],
        'p_delta': int.tryParse(ctrl.text) ?? 0,
        'p_reason': 'Desktop'
      });
      widget.controller.refresh();
    }
  }

  Future<void> _discount(BuildContext context, Map<String, dynamic> c) async {
    final ctrl = TextEditingController(text: '${c['discount_percent']}');
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(tr('Chegirma')),
                content: TextField(
                    controller: ctrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: tr('Foiz'))),
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
        await widget.controller.repository.client
            .rpc('customer_set_discount', params: {
          'p_customer_id': c['id'],
          'p_percent': int.tryParse(ctrl.text) ?? 0,
        });
        widget.controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _loyalty(BuildContext context) async {
    final repo = widget.controller.repository;
    final clubId = widget.controller.context!.clubId;
    final basePercent = TextEditingController(
        text:
            '${widget.controller.context!.club['loyalty_earn_percent'] ?? 0}');
    final visitBonus = TextEditingController(
        text: '${widget.controller.context!.club['visit_bonus_points'] ?? 0}');

    Future<List<Map<String, dynamic>>> loadTiers() => repo.client
        .from('loyalty_tiers')
        .select()
        .eq('club_id', clubId)
        .eq('active', true)
        .order('sort_order', ascending: true)
        .then(rowList);

    await showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          var tiersFuture = loadTiers();
          void reload() => setState(() => tiersFuture = loadTiers());
          return AlertDialog(
            title: Text(tr('Sodiqlik dasturi')),
            content: SizedBox(
              width: 560,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: TextField(
                          controller: basePercent,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: tr('Darajasiz mijozlar uchun bonus %'),
                              helperText:
                                  tr('Darajasi bo\'lmagan mijozlar uchun')),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: visitBonus,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: tr('Tashrif uchun bonus'),
                              helperText:
                                  tr('Kuniga 1 marta, 0 — o\'chirilgan')),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 18),
                    Row(children: [
                      Text(tr('Darajalar'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 16)),
                      const Spacer(),
                      TextButton.icon(
                        onPressed: () async {
                          await _editTier(context, clubId, null);
                          reload();
                        },
                        icon: const Icon(Icons.add_rounded, size: 18),
                        label: Text(tr('Daraja')),
                      ),
                    ]),
                    Text(
                      tr('Mijoz sotib olishlar summasiga qarab o\'zi mos keladigan eng yuqori darajaga tushadi.'),
                      style: TextStyle(color: VColors.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 8),
                    FutureBuilder<List<Map<String, dynamic>>>(
                      future: tiersFuture,
                      builder: (context, snap) {
                        final tiers = snap.data ?? const [];
                        if (!snap.hasData) {
                          return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 20),
                              child: Center(
                                  child: SizedBox(
                                      width: 22,
                                      height: 22,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))));
                        }
                        return Column(
                          children: tiers
                              .map((t) => ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(
                                        Icons.workspace_premium_outlined,
                                        color: VColors.green),
                                    title: Text('${t['name']}',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w800)),
                                    subtitle: Text(LocaleController
                                            .instance.isRu
                                        ? 'от ${money(t['min_total_spent'])} · бонус ${t['earn_percent']}% · скидка ${t['discount_percent']}%'
                                        : '${money(t['min_total_spent'])} dan · bonus ${t['earn_percent']}% · chegirma ${t['discount_percent']}%'),
                                    trailing: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        IconButton(
                                          icon: const Icon(Icons.edit_outlined,
                                              size: 19),
                                          onPressed: () async {
                                            await _editTier(context, clubId, t);
                                            reload();
                                          },
                                        ),
                                        IconButton(
                                          icon: Icon(
                                              Icons.delete_outline_rounded,
                                              size: 19,
                                              color: VColors.red),
                                          onPressed: () async {
                                            await repo.client
                                                .from('loyalty_tiers')
                                                .update({'active': false}).eq(
                                                    'id', t['id']);
                                            reload();
                                          },
                                        ),
                                      ],
                                    ),
                                  ))
                              .toList(),
                        );
                      },
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          try {
                            await repo.client.rpc('app_refresh_club_tiers',
                                params: {'p_club_id': clubId});
                            if (context.mounted) {
                              showDone(
                                  context, tr('Darajalar qayta hisoblandi'));
                            }
                            widget.controller.refresh();
                          } catch (e) {
                            if (context.mounted) showError(context, e);
                          }
                        },
                        icon: const Icon(Icons.refresh_rounded, size: 18),
                        label: Text(tr('Mijozlar darajasini qayta hisoblash')),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(tr('Yopish'))),
              FilledButton(
                onPressed: () async {
                  try {
                    await repo.client.from('clubs').update({
                      'loyalty_earn_percent':
                          int.tryParse(basePercent.text) ?? 0,
                      'visit_bonus_points': int.tryParse(visitBonus.text) ?? 0,
                    }).eq('id', clubId);
                    await widget.controller.reloadContext();
                    if (context.mounted) Navigator.pop(context);
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
                child: Text(tr('Saqlash')),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _editTier(
      BuildContext context, String clubId, Map<String, dynamic>? tier) async {
    final name = TextEditingController(text: '${tier?['name'] ?? ''}');
    final minSpent =
        TextEditingController(text: '${tier?['min_total_spent'] ?? 0}');
    final earnPercent =
        TextEditingController(text: '${tier?['earn_percent'] ?? 0}');
    final discountPercent =
        TextEditingController(text: '${tier?['discount_percent'] ?? 0}');
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: Text(
                    tr(tier == null ? 'Yangi daraja' : 'Darajani tahrirlash')),
                content: SizedBox(
                    width: 420,
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      TextField(
                          controller: name,
                          decoration: InputDecoration(labelText: tr('Nomi'))),
                      const SizedBox(height: 10),
                      TextField(
                          controller: minSpent,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                              labelText: tr('Boshlang\'ich summa (so\'m)'))),
                      const SizedBox(height: 10),
                      TextField(
                          controller: earnPercent,
                          keyboardType: TextInputType.number,
                          decoration:
                              InputDecoration(labelText: tr('Bonus %'))),
                      const SizedBox(height: 10),
                      TextField(
                          controller: discountPercent,
                          keyboardType: TextInputType.number,
                          decoration:
                              InputDecoration(labelText: tr('Chegirma %'))),
                    ])),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(tr('Bekor qilish'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(tr('Saqlash')))
                ]));
    if (ok != true) return;
    final data = {
      'club_id': clubId,
      'name': name.text.trim(),
      'min_total_spent': int.tryParse(minSpent.text) ?? 0,
      'earn_percent': int.tryParse(earnPercent.text) ?? 0,
      'discount_percent': int.tryParse(discountPercent.text) ?? 0,
    };
    try {
      if (tier == null) {
        await widget.controller.repository.client
            .from('loyalty_tiers')
            .insert(data);
      } else {
        await widget.controller.repository.client
            .from('loyalty_tiers')
            .update(data)
            .eq('id', tier['id']);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Current loyalty tier + progress toward the next one — mirrors the badge
/// shown on the customer card in the reference design (tier name, earn %,
/// a progress bar, and "X so'm left to reach the next tier").
class _TierProgress extends StatelessWidget {
  const _TierProgress({required this.customer, required this.tiers});
  final Map<String, dynamic> customer;
  final List<Map<String, dynamic>> tiers;

  @override
  Widget build(BuildContext context) {
    if (tiers.isEmpty) return const SizedBox.shrink();
    final tier = customer['loyalty_tiers'];
    final currentId = tier is Map ? '${tier['id']}' : null;
    var index = tiers.indexWhere((t) => '${t['id']}' == currentId);
    if (index < 0) index = 0;
    final current = tiers[index];
    final next = index + 1 < tiers.length ? tiers[index + 1] : null;
    final spent = (customer['total_spent'] as num?) ?? 0;
    final currentMin = (current['min_total_spent'] as num?) ?? 0;
    final nextMin =
        next == null ? null : (next['min_total_spent'] as num?) ?? 0;
    final progress = next == null
        ? 1.0
        : ((spent - currentMin) /
                ((nextMin! - currentMin).clamp(1, double.infinity)))
            .clamp(0.0, 1.0)
            .toDouble();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: VColors.greenSoft,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VColors.green.withValues(alpha: .3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.workspace_premium_rounded,
                color: VColors.green, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text('${current['name'] ?? ''}',
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 16)),
            ),
            Pill('${tr('bonus')} ${current['earn_percent'] ?? 0}%',
                color: VColors.green, foreground: Colors.black87),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: VColors.field,
              valueColor: AlwaysStoppedAnimation(VColors.green),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            next == null
                ? tr('Eng yuqori daraja')
                : (LocaleController.instance.isRu
                    ? 'Ещё ${money((nextMin! - spent).clamp(0, nextMin))} до уровня «${next['name']}»'
                    : '«${next['name']}» darajasigacha yana ${money((nextMin! - spent).clamp(0, nextMin))}'),
            style: TextStyle(color: VColors.muted, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}

class _Info extends StatelessWidget {
  const _Info(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(children: [
        Text(label, style: TextStyle(color: VColors.muted)),
        const Spacer(),
        Text(value, style: const TextStyle(fontWeight: FontWeight.w800))
      ]));
}
