import 'package:flutter/material.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class WaitlistPage extends StatelessWidget {
  const WaitlistPage({super.key, required this.controller});
  final ClubController controller;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(30),
        child: Column(children: [
          PageHeader(title: tr('Navbat'), actions: [
            IconButton(
                onPressed: controller.refresh,
                icon: const Icon(Icons.refresh_rounded)),
            FilledButton.icon(
                onPressed: () => _join(context),
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Navbatga')))
          ]),
          const SizedBox(height: 22),
          Expanded(
              child: AsyncPane<List<Map<String, dynamic>>>(
                  future: controller.repository
                      .waitlist(controller.context!.clubId),
                  builder: (context, rows) {
                    if (rows.isEmpty) {
                      return EmptyState(
                          icon: Icons.hourglass_empty_rounded,
                          title: tr('Navbat bo\'sh'),
                          subtitle: tr('Hozir kutayotgan mijoz yo\'q'));
                    }
                    return ListView.separated(
                        itemCount: rows.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 10),
                        itemBuilder: (_, i) {
                          final r = rows[i];
                          return VCard(
                              child: Row(children: [
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(
                                      '${r['customer_name'] ?? r['full_name'] ?? tr('Mijoz')}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w800,
                                          fontSize: 17)),
                                  const SizedBox(height: 4),
                                  Text(
                                      '${tr(r['resource_family'] ?? 'Bilyard')} · ${tr('kutmoqda')} ${durationFrom(r['joined_at'])}',
                                      style: TextStyle(
                                          color: VColors.muted)),
                                  const SizedBox(height: 6),
                                  Text(
                                      '${tr('Chegirma to\'plandi')}: ${money(r['accrued_discount'] ?? 0)}',
                                      style: TextStyle(
                                          color: VColors.green,
                                          fontWeight: FontWeight.w800))
                                ])),
                            TextButton(
                                onPressed: () => _cancel(context, r),
                                child: Text(tr('Bekor qilish'))),
                            const SizedBox(width: 10),
                            FilledButton(
                                onPressed: () => _seat(context, r),
                                child: Text(tr('O\'tqazish'))),
                          ]));
                        });
                  }))
        ]),
      );

  Future<void> _join(BuildContext context) async {
    final customers =
        await controller.repository.customers(controller.context!.clubId);
    if (!context.mounted) return;
    String? customerId;
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
                    title: Text(tr('Navbatga qo\'shish')),
                    content: SizedBox(
                        width: 480,
                        child: DropdownButtonFormField<String>(
                            initialValue: customerId,
                            decoration:
                                InputDecoration(labelText: tr('Mijoz')),
                            items: customers
                                .map((c) => DropdownMenuItem(
                                    value: '${c['id']}',
                                    child: Text(
                                        '${c['full_name'] ?? c['phone']}')))
                                .toList(),
                            onChanged: (v) => setState(() => customerId = v))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(tr('Bekor qilish'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(tr('Qo\'shish')))
                    ])));
    if (ok == true && customerId != null) {
      try {
        await controller.repository.client.rpc('waitlist_join', params: {
          'p_club_id': controller.context!.clubId,
          'p_customer_id': customerId,
          'p_resource_family': 'BILLIARD'
        });
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _cancel(BuildContext context, Map<String, dynamic> r) async {
    try {
      await controller.repository.client.rpc('waitlist_cancel',
          params: {'p_entry_id': r['id'], 'p_reason': 'Bekor qilindi'});
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _seat(BuildContext context, Map<String, dynamic> r) async {
    final resources =
        await controller.repository.resources(controller.context!.clubId);
    if (!context.mounted) return;
    final free = resources.where((e) => e['status'] == 'FREE').toList();
    String? id = free.firstOrNull?['id']?.toString();
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, setState) => AlertDialog(
                    title: Text(tr('Joy tanlang')),
                    content: SizedBox(
                        width: 430,
                        child: DropdownButtonFormField<String>(
                            initialValue: id,
                            items: free
                                .map((e) => DropdownMenuItem(
                                    value: '${e['id']}',
                                    child: Text('${e['name']}')))
                                .toList(),
                            onChanged: (v) => setState(() => id = v))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(tr('Bekor qilish'))),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(tr('O\'tqazish')))
                    ])));
    if (ok == true && id != null) {
      final resource = free.firstWhere((e) => '${e['id']}' == id);
      try {
        final result = rowMap(await controller.repository.client.rpc('waitlist_seat', params: {
          'p_entry_id': r['id'],
          'p_resource_id': id,
          'p_tariff_id': resource['default_tariff_id'],
          'p_billing_mode': 'POSTPAID'
        }));
        // waitlist_seat starts the session server-side (same as the normal
        // "Ishga tushirish" dialog), so it needs the same local relay
        // switch -- otherwise a table seated from the queue never gets its
        // light turned on.
        try {
          await controller.repository.switchRelayDevice(result['relay_device'], true);
        } catch (_) {}
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }
}
