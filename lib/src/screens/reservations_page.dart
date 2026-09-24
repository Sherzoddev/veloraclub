import 'package:flutter/material.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class ReservationsPage extends StatelessWidget {
  const ReservationsPage({super.key, required this.controller});
  final ClubController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(30),
      child: Column(
        children: [
          PageHeader(
            title: tr('Bronlar'),
            actions: [
              FilledButton.icon(
                onPressed: () => _newReservation(context),
                icon: const Icon(Icons.add_rounded),
                label: Text(tr('Yangi bron')),
              ),
            ],
          ),
          const SizedBox(height: 22),
          Expanded(
            child: AsyncPane<List<Map<String, dynamic>>>(
              future: controller.repository
                  .reservations(controller.context!.clubId),
              builder: (context, rows) {
                final visible =
                    rows.where((r) => r['status'] != 'cancelled').toList();
                if (visible.isEmpty) {
                  return EmptyState(
                      icon: Icons.event_available_outlined,
                      title: tr('Bronlar yo\'q'),
                      subtitle: tr('Yangi bron yaratishingiz mumkin'));
                }
                return ListView.separated(
                  itemCount: visible.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (context, i) {
                    final row = visible[i];
                    final resource = row['resources'];
                    return VCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 14),
                      child: Row(
                        children: [
                          Icon(Icons.event_available_outlined,
                              color: VColors.orange, size: 28),
                          const SizedBox(width: 18),
                          Expanded(
                            child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                      '${resource is Map ? resource['name'] : tr('Joy')} — ${row['customer_name'] ?? row['customers']?['full_name'] ?? ''}',
                                      style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w700)),
                                  Text(
                                      '${shortDate(row['starts_at'])} — ${shortDate(row['ends_at'])} · ${row['players_count']} ${tr('o\'yinchi')} · ${row['phone'] ?? ''}',
                                      style: TextStyle(
                                          color: VColors.muted)),
                                ]),
                          ),
                          Pill('${row['status']}'.toUpperCase(),
                              color: VColors.field, foreground: VColors.muted),
                          const SizedBox(width: 12),
                          TextButton.icon(
                              onPressed: () => _start(context, row),
                              icon: const Icon(Icons.play_arrow_rounded),
                              label: Text(tr('Boshlash'))),
                          PopupMenuButton<String>(
                              itemBuilder: (_) => [
                                    PopupMenuItem(
                                        value: 'cancel',
                                        child: Text(tr('Bekor qilish')))
                                  ],
                              onSelected: (_) => _cancel(context, row)),
                        ],
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
  }

  Future<void> _newReservation(BuildContext context) async {
    final resources =
        await controller.repository.resources(controller.context!.clubId);
    if (!context.mounted) return;
    String? resourceId = resources.isEmpty ? null : '${resources.first['id']}';
    final name = TextEditingController();
    final phone = TextEditingController();
    final date = ValueNotifier(DateTime.now().add(const Duration(hours: 1)));
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: Text(tr('Yangi bron')),
              content: SizedBox(
                  width: 500,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    DropdownButtonFormField<String>(
                        initialValue: resourceId,
                        decoration: InputDecoration(labelText: tr('Joy')),
                        items: resources
                            .map((r) => DropdownMenuItem(
                                value: '${r['id']}',
                                child: Text('${r['name']}')))
                            .toList(),
                        onChanged: (v) => resourceId = v),
                    const SizedBox(height: 12),
                    TextField(
                        controller: name,
                        decoration:
                            InputDecoration(labelText: tr('Mijoz ismi'))),
                    const SizedBox(height: 12),
                    TextField(
                        controller: phone,
                        decoration:
                            InputDecoration(labelText: tr('Telefon'))),
                    const SizedBox(height: 12),
                    ValueListenableBuilder(
                        valueListenable: date,
                        builder: (_, value, __) => Row(children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                    onPressed: () async {
                                      final d = await showDatePicker(
                                          context: context,
                                          firstDate: DateTime.now(),
                                          lastDate: DateTime.now()
                                              .add(const Duration(days: 365)),
                                          initialDate: value);
                                      if (d != null) {
                                        date.value = DateTime(d.year, d.month,
                                            d.day, value.hour, value.minute);
                                      }
                                    },
                                    icon: const Icon(
                                        Icons.calendar_today_outlined),
                                    label: Text(
                                        shortDate(value.toIso8601String()))),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: OutlinedButton.icon(
                                    onPressed: () async {
                                      final t = await showTimePicker(
                                          context: context,
                                          initialTime: TimeOfDay(
                                              hour: value.hour,
                                              minute: value.minute));
                                      if (t != null) {
                                        date.value = DateTime(
                                            value.year,
                                            value.month,
                                            value.day,
                                            t.hour,
                                            t.minute);
                                      }
                                    },
                                    icon: const Icon(
                                        Icons.access_time_rounded),
                                    label: Text(
                                        '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}')),
                              ),
                            ])),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr('Bekor qilish'))),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr('Saqlash')))
              ],
            ));
    if (ok != true || resourceId == null) return;
    try {
      await controller.repository.client.from('reservations').insert({
        'club_id': controller.context!.clubId,
        'resource_id': resourceId,
        'customer_name': name.text.trim().isEmpty ? 'Mijoz' : name.text.trim(),
        'phone': phone.text.trim(),
        'starts_at': date.value.toUtc().toIso8601String(),
        'ends_at':
            date.value.add(const Duration(hours: 1)).toUtc().toIso8601String(),
        'status': 'pending',
        'created_by': controller.repository.user!.id,
      });
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _start(BuildContext context, Map<String, dynamic> row) async {
    final resources =
        await controller.repository.resources(controller.context!.clubId);
    final resource = resources
        .where((r) => '${r['id']}' == '${row['resource_id']}')
        .firstOrNull;
    if (resource == null || resource['default_tariff_id'] == null) return;
    try {
      final session = await controller.repository.startSession(
          clubId: controller.context!.clubId,
          resourceId: '${resource['id']}',
          tariffId: '${resource['default_tariff_id']}',
          customerId: row['customer_id']?.toString());
      await controller.repository.client.from('reservations').update({
        'status': 'arrived',
        'session_id': session['id'] ?? session['session_id']
      }).eq('id', row['id']);
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _cancel(BuildContext context, Map<String, dynamic> row) async {
    try {
      await controller.repository.client
          .from('reservations')
          .update({'status': 'cancelled'}).eq('id', row['id']);
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
