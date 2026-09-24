import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../i18n.dart';
import '../services/device_access_service.dart';
import '../services/native_file_picker.dart';
import '../services/printer_service.dart';
import '../services/receipt_builder.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int tab = 0;
  static const tabs = [
    'Resurslar',
    'Tariflar',
    'Chek',
    'Telegram-bot',
    'Rele',
    'Token',
  ];

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Sozlamalar',
                  style: const TextStyle(
                      fontWeight: FontWeight.w900, fontSize: 21)),
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 42,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 20),
              itemCount: tabs.length,
              itemBuilder: (_, index) {
                final active = index == tab;
                return InkWell(
                  onTap: () => setState(() => tab = index),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Center(
                            child: Text(tabs[index],
                                style: TextStyle(
                                    color: active
                                        ? VColors.green
                                        : VColors.muted,
                                    fontWeight: FontWeight.w800,
                                    fontSize: 14)),
                          ),
                        ),
                        Container(
                          height: 2,
                          width: active ? 22 : 0,
                          margin: const EdgeInsets.only(bottom: 1),
                          color: VColors.green,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Divider(height: 1, color: VColors.line),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: [
                _resources(),
                _tariffs(),
                _ReceiptSettings(controller: widget.controller),
                _TelegramBotSettings(controller: widget.controller),
                _relays(),
                _token(),
              ][tab],
            ),
          ),
        ],
      );

  Widget _resources() => AsyncPane<List<dynamic>>(
        future: Future.wait([
          widget.controller.repository
              .resources(widget.controller.context!.clubId),
          widget.controller.repository
              .zones(widget.controller.context!.clubId),
          widget.controller.repository
              .resourceTypes(widget.controller.context!.clubId),
          widget.controller.repository
              .relayDevices(widget.controller.context!.clubId),
        ]),
        builder: (context, values) {
          final rows = (values[0] as List).cast<Map<String, dynamic>>();
          final zones = (values[1] as List).cast<Map<String, dynamic>>();
          final types = (values[2] as List).cast<Map<String, dynamic>>();
          final relays = (values[3] as List).cast<Map<String, dynamic>>();
          final club = widget.controller.context!.club;
          final hasPs = club['has_playstation'] != false;
          final hasBilliard = club['has_billiard'] == true;

          final grouped = <String, List<Map<String, dynamic>>>{};
          for (final row in rows) {
            final zone = '${row['zone'] ?? ''}'.trim();
            grouped.putIfAbsent(zone.isEmpty ? 'Zonasiz' : zone, () => []).add(row);
          }
          for (final list in grouped.values) {
            list.sort((a, b) {
              final an = (a['number'] as num?) ?? 0;
              final bn = (b['number'] as num?) ?? 0;
              return an.compareTo(bn);
            });
          }

          return ListView(
            children: [
              VCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Klub yo\'nalishlari',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(
                      'O\'chirilgan yo\'nalish zal xaritasidan, tariflardan va kassadan butunlay yo\'qoladi. Yaratilgan joylar o\'chirilmaydi.',
                      style: TextStyle(color: VColors.muted, fontSize: 12.5),
                    ),
                    const SizedBox(height: 12),
                    _familyRow(context, Icons.sports_esports_rounded,
                        'PlayStation', hasPs, 'has_playstation'),
                    const SizedBox(height: 10),
                    _familyRow(context, Icons.radio_button_checked_rounded,
                        'Billiard', hasBilliard, 'has_billiard'),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              if (hasBilliard)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => _addResource(context, 'BILLIARD', types, zones, relays),
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('Billiard qo\'shish'),
                      style: FilledButton.styleFrom(
                        foregroundColor: Colors.black87,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              if (hasPs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: () => _addResource(context, 'PLAYSTATION', types, zones, relays),
                      icon: const Icon(Icons.add, size: 17),
                      label: const Text('PlayStation qo\'shish'),
                      style: FilledButton.styleFrom(
                        foregroundColor: Colors.black87,
                        minimumSize: const Size(0, 38),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        textStyle: const TextStyle(
                            fontSize: 13, fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 6),
              Text('Kategoriyalar / zonalar',
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final z in zones)
                  _CategoryPill(
                    label: '${z['name']}',
                    onDelete: () async {
                      await widget.controller.repository.client
                          .from('zones')
                          .update({'active': false}).eq('id', z['id']);
                      widget.controller.refresh();
                    },
                  ),
                _AddCategoryPill(onTap: () => _addZone(context)),
              ]),
              const SizedBox(height: 18),
              for (final entry in grouped.entries) ...[
                Text(entry.key,
                    style: const TextStyle(
                        fontWeight: FontWeight.w900, fontSize: 15)),
                const SizedBox(height: 8),
                ...entry.value.map((row) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ResourceRow(
                        row: row,
                        relays: relays,
                        controller: widget.controller,
                        onEdit: () =>
                            _addResource(context, null, types, zones, relays, row),
                      ),
                    )),
                const SizedBox(height: 10),
              ],
            ],
          );
        },
      );

  Widget _familyRow(BuildContext context, IconData icon, String label,
      bool value, String field) {
    return Row(children: [
      Icon(icon, size: 20, color: VColors.muted),
      const SizedBox(width: 10),
      Expanded(
          child: Text(label,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
      _VSwitch(
        value: value,
        onChanged: (v) async {
          if (!v) {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: Text('$label ni o\'chirish'),
                content: const Text(
                    'Bu yo\'nalish zal xaritasidan, tariflardan va kassadan butunlay yo\'qoladi. Yaratilgan joylar o\'chirilmaydi.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Bekor qilish')),
                  FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: VColors.red),
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('O\'chirish')),
                ],
              ),
            );
            if (confirmed != true) return;
          }
          await widget.controller.repository.client
              .from('clubs')
              .update({field: v}).eq('id', widget.controller.context!.clubId);
          widget.controller.refresh();
        },
      ),
    ]);
  }

  Future<void> _addZone(BuildContext context) async {
    final name = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Yangi kategoriya'),
        content: TextField(
            controller: name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Nomi')),
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
    await widget.controller.repository.client.from('zones').insert({
      'club_id': widget.controller.context!.clubId,
      'name': name.text.trim(),
      'active': true,
    });
    widget.controller.refresh();
  }

  Future<void> _addResource(
    BuildContext context,
    String? family,
    List<Map<String, dynamic>> types,
    List<Map<String, dynamic>> zones,
    List<Map<String, dynamic>> relays, [
    Map<String, dynamic>? existing,
  ]) async {
    final name = TextEditingController(text: '${existing?['name'] ?? ''}');
    final number = TextEditingController(
        text: existing?['number'] == null ? '' : '${existing!['number']}');
    final matchingTypes = family == null
        ? types
        : types.where((t) => t['family'] == family).toList();
    String? typeId = existing?['resource_type_id']?.toString() ??
        matchingTypes.firstOrNull?['id']?.toString();
    String? zoneName = existing?['zone']?.toString();
    String? tariffId = existing?['default_tariff_id']?.toString();
    String? relayId = existing?['relay_device_id']?.toString();
    final relayChannel = TextEditingController(
        text: existing?['relay_channel'] == null
            ? ''
            : '${existing!['relay_channel']}');
    final tariffs = await widget.controller.repository
        .tariffs(widget.controller.context!.clubId);
    if (!context.mounted) return;
    tariffId ??= tariffs.firstOrNull?['id']?.toString();

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Yangi joy' : 'Joyni tahrirlash'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Nomi')),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(
                    flex: 3,
                    child: DropdownButtonFormField<String>(
                      initialValue: typeId,
                      decoration: const InputDecoration(labelText: 'Turi'),
                      items: matchingTypes
                          .map((row) => DropdownMenuItem(
                              value: '${row['id']}', child: Text('${row['name']}')))
                          .toList(),
                      onChanged: (value) => setDialogState(() => typeId = value),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 1,
                    child: TextField(
                        controller: number,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: '№')),
                  ),
                ]),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: zoneName,
                  decoration:
                      const InputDecoration(labelText: 'Zona / kategoriya'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Zonasiz')),
                    ...zones.map((z) => DropdownMenuItem<String?>(
                        value: '${z['name']}', child: Text('${z['name']}'))),
                  ],
                  onChanged: (value) => setDialogState(() => zoneName = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: tariffId,
                  decoration:
                      const InputDecoration(labelText: 'Standart tarif'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Belgilanmagan')),
                    ...tariffs.map((row) => DropdownMenuItem<String?>(
                        value: '${row['id']}', child: Text('${row['name']}'))),
                  ],
                  onChanged: (value) => setDialogState(() => tariffId = value),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String?>(
                  initialValue: relayId,
                  decoration: const InputDecoration(labelText: 'Rele'),
                  items: [
                    const DropdownMenuItem<String?>(
                        value: null, child: Text('Relesiz')),
                    ...relays.map((r) => DropdownMenuItem<String?>(
                        value: '${r['id']}', child: Text('${r['name']}'))),
                  ],
                  onChanged: (value) => setDialogState(() => relayId = value),
                ),
                if (relayId != null) ...[
                  const SizedBox(height: 10),
                  TextField(
                      controller: relayChannel,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Kanal raqami')),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Bekor qilish')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Saqlash')),
          ],
        ),
      ),
    );
    if (approved != true || name.text.trim().isEmpty) return;
    final values = {
      'club_id': widget.controller.context!.clubId,
      'resource_type_id': typeId,
      'default_tariff_id': tariffId,
      'name': name.text.trim(),
      'number': int.tryParse(number.text),
      'zone': zoneName,
      'relay_device_id': relayId,
      'relay_channel': relayId == null ? null : int.tryParse(relayChannel.text),
    };
    if (existing == null) {
      values['status'] = 'FREE';
      values['active'] = true;
      await widget.controller.repository.client.from('resources').insert(values);
    } else {
      await widget.controller.repository.client
          .from('resources')
          .update(values)
          .eq('id', existing['id']);
    }
    widget.controller.refresh();
  }

  Widget _tariffs() => AsyncPane<List<dynamic>>(
        future: Future.wait([
          widget.controller.repository
              .tariffs(widget.controller.context!.clubId),
          widget.controller.repository
              .discounts(widget.controller.context!.clubId),
        ]),
        builder: (context, values) {
          final rows = (values[0] as List).cast<Map<String, dynamic>>();
          final discounts = (values[1] as List).cast<Map<String, dynamic>>();
          return ListView(
            children: [
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => _editTariff(context),
                  icon: const Icon(Icons.add),
                  label: const Text('Tarif qo\'shish'),
                ),
              ),
              const SizedBox(height: 15),
              ...rows.map(
                (tariff) => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: VCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${tariff['name']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 17)),
                              Text('${money(tariff['price_per_hour'])} so\'m / soat',
                                  style: TextStyle(color: VColors.subtle)),
                            ],
                          ),
                        ),
                        IconButton(
                            tooltip: 'Vaqt bo\'yicha narxlar',
                            onPressed: () {},
                            icon: const Icon(Icons.schedule_outlined)),
                        Switch(
                          value: tariff['active'] != false,
                          onChanged: (v) async {
                            await widget.controller.repository.client
                                .from('tariffs')
                                .update({'active': v}).eq('id', tariff['id']);
                            widget.controller.refresh();
                          },
                        ),
                        IconButton(
                          icon: Icon(Icons.delete_outline_rounded, color: VColors.red),
                          onPressed: () async {
                            await widget.controller.repository.client
                                .from('tariffs')
                                .update({'archived_at': DateTime.now().toIso8601String(), 'active': false})
                                .eq('id', tariff['id']);
                            widget.controller.refresh();
                          },
                        ),
                        IconButton(
                            onPressed: () => _editTariff(context, tariff),
                            icon: const Icon(Icons.edit_outlined)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Row(children: [
                const Text('Chegirmalar va aksiyalar',
                    style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17)),
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: () => _editDiscount(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Yangi chegirma'),
                ),
              ]),
              const SizedBox(height: 8),
              Text(
                'Nomlangan chegirmalar kassirga to\'lovni rasmiylashtirishda tezkor tanlash uchun mavjud (har safar summani qo\'lda kiritish o\'rniga).',
                style: TextStyle(color: VColors.muted),
              ),
              const SizedBox(height: 14),
              ...discounts.map((d) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: VCard(
                      child: Row(children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${d['name']}',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.w800, fontSize: 16)),
                              Text(
                                  '${d['kind'] == 'PERCENT' ? '-${d['value']}%' : '-${money(d['value'])}'}${d['applies_to'] == 'TIME' ? ' · faqat vaqtga' : ''}',
                                  style: TextStyle(color: VColors.subtle)),
                            ],
                          ),
                        ),
                        Switch(
                          value: d['active'] != false,
                          onChanged: (v) async {
                            await widget.controller.repository.client
                                .from('discounts')
                                .update({'active': v}).eq('id', d['id']);
                            widget.controller.refresh();
                          },
                        ),
                        IconButton(
                            onPressed: () => _editDiscount(context, d),
                            icon: const Icon(Icons.edit_outlined)),
                      ]),
                    ),
                  )),
            ],
          );
        },
      );

  Future<void> _editDiscount(BuildContext context,
      [Map<String, dynamic>? discount]) async {
    final name = TextEditingController(text: '${discount?['name'] ?? ''}');
    final value = TextEditingController(
        text: discount == null ? '' : '${discount['value']}');
    var kind = '${discount?['kind'] ?? 'PERCENT'}';
    var appliesTo = '${discount?['applies_to'] ?? 'ALL'}';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(discount == null ? 'Yangi chegirma' : 'Chegirma'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nomi')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: 'Turi'),
                  items: const [
                    DropdownMenuItem(value: 'PERCENT', child: Text('Foizda (%)')),
                    DropdownMenuItem(value: 'AMOUNT', child: Text('Summada (so\'m)')),
                  ],
                  onChanged: (v) => setDialogState(() => kind = v ?? kind),
                ),
                const SizedBox(height: 10),
                TextField(
                    controller: value,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Qiymati')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: appliesTo,
                  decoration: const InputDecoration(labelText: 'Nimaga qo\'llanadi'),
                  items: const [
                    DropdownMenuItem(value: 'ALL', child: Text('Butun chek (vaqt + bar)')),
                    DropdownMenuItem(value: 'TIME', child: Text('Faqat vaqtga (bar hisobga olinmaydi)')),
                  ],
                  onChanged: (v) => setDialogState(() => appliesTo = v ?? appliesTo),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Bekor qilish')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Saqlash')),
          ],
        ),
      ),
    );
    if (approved != true || name.text.trim().isEmpty) return;
    final values = {
      'club_id': widget.controller.context!.clubId,
      'name': name.text.trim(),
      'kind': kind,
      'value': int.tryParse(value.text) ?? 0,
      'applies_to': appliesTo,
      'active': true,
    };
    if (discount == null) {
      await widget.controller.repository.client.from('discounts').insert(values);
    } else {
      await widget.controller.repository.client
          .from('discounts')
          .update(values)
          .eq('id', discount['id']);
    }
    widget.controller.refresh();
  }

  Future<void> _editTariff(BuildContext context,
      [Map<String, dynamic>? tariff]) async {
    final name = TextEditingController(text: '${tariff?['name'] ?? ''}');
    final price =
        TextEditingController(text: '${tariff?['price_per_hour'] ?? ''}');
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tariff == null ? 'Yangi tarif' : 'Tarif'),
        content: SizedBox(
          width: 450,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Nomi')),
              const SizedBox(height: 10),
              TextField(
                  controller: price,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Soat narxi')),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Bekor qilish')),
          FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Saqlash')),
        ],
      ),
    );
    if (approved != true) return;
    final values = {
      'club_id': widget.controller.context!.clubId,
      'name': name.text.trim(),
      'price_per_hour': int.tryParse(price.text) ?? 0,
      'kind': 'HOURLY',
    };
    if (tariff == null) {
      await widget.controller.repository.client.from('tariffs').insert(values);
    } else {
      await widget.controller.repository.client
          .from('tariffs')
          .update(values)
          .eq('id', tariff['id']);
    }
    widget.controller.refresh();
  }


  Widget _relays() => AsyncPane<List<Map<String, dynamic>>>(
        future: widget.controller.repository
            .relayDevices(widget.controller.context!.clubId),
        builder: (context, rows) => ListView(
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => _editRelay(context),
                icon: const Icon(Icons.add),
                label: const Text('Yangi rele'),
              ),
            ),
            const SizedBox(height: 16),
            ...rows.map(
              (relay) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: VCard(
                  child: Row(
                    children: [
                      Icon(
                          relay['provider'] == 'USB_SERIAL'
                              ? Icons.usb_rounded
                              : relay['provider'] == 'MOCK'
                                  ? Icons.wifi_rounded
                                  : Icons.settings_remote_outlined,
                          color: VColors.green),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('${relay['name']}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w900, fontSize: 18)),
                            Text(
                                '${_providerLabels[relay['provider']] ?? relay['provider']} · ${relay['channels']} kanal',
                                style: TextStyle(color: VColors.muted)),
                          ],
                        ),
                      ),
                      IconButton(
                          onPressed: () => _editRelay(context, relay),
                          icon: const Icon(Icons.edit_outlined)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );

  static const _providerLabels = {
    'USB_SERIAL': 'USB-rele (kassaga kabel bilan)',
    'MOCK': 'Demo-rele',
    'GENERIC_HTTP': 'Tarmoqdagi rele (HTTP)',
    'SHELLY': 'Shelly',
    'SONOFF': 'Sonoff',
    'ESP32': 'ESP32',
    'TUYA': 'Tuya',
    'MQTT': 'MQTT',
  };

  Future<void> _editRelay(BuildContext context,
      [Map<String, dynamic>? existing]) async {
    final name = TextEditingController(text: '${existing?['name'] ?? ''}');
    final channels =
        TextEditingController(text: '${existing?['channels'] ?? 1}');
    var provider = '${existing?['provider'] ?? 'USB_SERIAL'}';
    var comPort = existing?['configuration'] is Map
        ? existing!['configuration']['port'] as String?
        : null;
    var enabled = existing?['enabled'] != false;
    var ports = PrinterService.listSerialPorts();

    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Yangi rele' : 'Releni tahrirlash'),
          content: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                    controller: name,
                    decoration: const InputDecoration(labelText: 'Nomi')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: provider,
                  decoration:
                      const InputDecoration(labelText: 'Ishlab chiqaruvchi'),
                  items: _providerLabels.entries
                      .map((e) => DropdownMenuItem(
                          value: e.key, child: Text(e.value)))
                      .toList(),
                  onChanged: (value) =>
                      setDialogState(() => provider = value ?? provider),
                ),
                if (provider == 'USB_SERIAL') ...[
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: comPort,
                        decoration: const InputDecoration(
                            labelText: 'Plata COM-porti'),
                        hint: const Text('Tanlanmagan'),
                        items: ports
                            .map((p) =>
                                DropdownMenuItem(value: p, child: Text(p)))
                            .toList(),
                        onChanged: (value) =>
                            setDialogState(() => comPort = value),
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          setDialogState(() => ports = PrinterService.listSerialPorts()),
                      icon: const Icon(Icons.refresh_rounded),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    'CH340 chipli plata ulangandan so\'ng COM-port sifatida ko\'rinadi',
                    style: TextStyle(color: VColors.subtle, fontSize: 12),
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: comPort == null
                          ? null
                          : () async {
                              try {
                                // 0xA0 <channel> <state> <checksum> --
                                // matches relay_controller.ino's firmware.
                                await PrinterService.printRawToSerial(
                                    comPort!,
                                    Uint8List.fromList(
                                        [0xA0, 0x01, 0x01, 0xA2]));
                                if (context.mounted) {
                                  showDone(context, 'Signal yuborildi');
                                }
                              } catch (e) {
                                if (context.mounted) showError(context, e);
                              }
                            },
                      icon: const Icon(Icons.bolt_outlined),
                      label: const Text('Tekshirish — 1-kanalni bosish'),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                TextField(
                    controller: channels,
                    keyboardType: TextInputType.number,
                    decoration:
                        const InputDecoration(labelText: 'Kanallar soni')),
                const SizedBox(height: 10),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Yoqilgan'),
                  value: enabled,
                  onChanged: (v) => setDialogState(() => enabled = v),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Bekor qilish')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Saqlash')),
          ],
        ),
      ),
    );
    if (approved != true) return;
    try {
      await widget.controller.repository.client.rpc(
        'app_admin_upsert_relay_device',
        params: {
          'p_club_id': widget.controller.context!.clubId,
          'p_id': existing?['id'],
          'p_name': name.text.trim(),
          'p_provider': provider,
          'p_api_base_url': null,
          'p_channels': int.tryParse(channels.text) ?? 1,
          'p_configuration':
              provider == 'USB_SERIAL' && comPort != null ? {'port': comPort} : <String, dynamic>{},
          'p_secret_ref': null,
          'p_enabled': enabled,
          'p_direct_control': provider == 'USB_SERIAL',
        },
      );
      widget.controller.refresh();
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  Widget _token() => _TokenSettings(controller: widget.controller);
}

class _TokenSettings extends StatefulWidget {
  const _TokenSettings({required this.controller});
  final ClubController controller;

  @override
  State<_TokenSettings> createState() => _TokenSettingsState();
}

class _TokenSettingsState extends State<_TokenSettings> {
  final _tokenCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _tokenCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        children: [
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.devices_outlined, color: VColors.green),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(tr('Boshqa muassasaga ulash'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 18)),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(
                  tr("Muassasa kodini ta'minotchi o'z botida beradi. Kiritilgan kod qaysi klubga tegishli bo'lsa, dastur o'sha klubni ochadi."),
                  style: TextStyle(color: VColors.muted),
                ),
                const SizedBox(height: 18),
                Text(tr('Muassasa kodi (64 belgi)'),
                    style: TextStyle(color: VColors.subtle, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: _tokenCtrl,
                  enabled: !_busy,
                  maxLines: 2,
                  decoration:
                      InputDecoration(hintText: tr("Kodni to'liq joylashtiring")),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _busy ? null : _connect,
                    child: _busy
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(tr('Ulash')),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  tr("Ulangandan so'ng dastur hisobdan chiqadi va yangi muassasa xodimining PIN-kodini so'raydi."),
                  style: TextStyle(color: VColors.subtle, fontSize: 13),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(Icons.logout_rounded, color: VColors.red),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(tr('Klubdan chiqish'),
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 18)),
                  ),
                ]),
                const SizedBox(height: 10),
                Text(
                  tr("Dastur bu qurilmadagi muassasa kodini unutadi va hisobdan chiqadi. Keyingi kirishda kod so'raladi — qaysi klubning kodini kiritsangiz, o'sha klub ochiladi."),
                  style: TextStyle(color: VColors.muted),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _leave,
                    icon: const Icon(Icons.logout_rounded),
                    label: Text(tr('Klubdan chiqish')),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: VColors.red,
                      side: BorderSide(color: VColors.red),
                      minimumSize: const Size(0, 48),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );

  Future<bool> _confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(tr('Bekor qilish'))),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr('Davom etish'))),
          ],
        ),
      ) ==
      true;

  // The club shown after login comes from the signed-in staff session, and
  // a PIN session belongs to exactly one club -- so switching clubs means
  // saving the new code *and* signing out, then logging in with a PIN from
  // the new club. Just joining the device server-side left the old session
  // (and the old saved code) in place, so the old club kept opening.
  Future<void> _connect() async {
    final token = _tokenCtrl.text.replaceAll(RegExp(r'\s'), '');
    if (token.isEmpty) return;
    final ok = await _confirm(
      tr('Boshqa muassasaga ulash'),
      tr('Qurilma yangi muassasaga ulanadi va dastur hisobdan chiqadi. Keyin yangi muassasa xodimining PIN-kodi bilan kirasiz.'),
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final client = widget.controller.repository.client;
      await DeviceAccessService(client: client).connectVenue(token);
      await client.auth.signOut();
    } catch (e) {
      if (mounted) showError(context, DeviceAccessService.readableError(e));
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _leave() async {
    final ok = await _confirm(
      tr('Klubdan chiqish'),
      tr("Dastur bu qurilmadagi muassasa kodini unutadi va hisobdan chiqadi. Keyingi kirishda kod so'raladi — qaysi klubning kodini kiritsangiz, o'sha klub ochiladi."),
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final client = widget.controller.repository.client;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(DeviceAccessService.venueTokenKey);
      DeviceAccessService.applyVenueToken(client, null);
      await client.auth.signOut();
    } catch (e) {
      if (mounted) showError(context, e);
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Fixed "paper" colors for the receipt preview: it simulates a physical
/// printed slip, so its text stays dark-on-white no matter which theme
/// (light/dark) the rest of the app is currently in.
abstract final class _Paper {
  static const ink = Color(0xFF101010);
  static const muted = Color(0xFF6B6B6B);
  static const bg = Colors.white;
}

class _ReceiptSettings extends StatefulWidget {
  const _ReceiptSettings({required this.controller});
  final ClubController controller;

  @override
  State<_ReceiptSettings> createState() => _ReceiptSettingsState();
}

class _ReceiptSettingsState extends State<_ReceiptSettings> {
  late final TextEditingController name;
  late final TextEditingController subtitle;
  late final TextEditingController phone;
  late final TextEditingController footer;
  late final TextEditingController qr;
  late final TextEditingController caption;
  late int paper;
  late bool enabled;
  late bool printCost;
  late String? logoUrl;
  late int fontTitle, fontTotal, fontMeta, fontItems, fontFooter, fontQrCaption;
  bool _uploadingLogo = false;

  @override
  void initState() {
    super.initState();
    final club = widget.controller.context!.club;
    name = TextEditingController(
        text: '${club['receipt_header'] ?? club['name']}');
    subtitle = TextEditingController(text: '${club['receipt_subtitle'] ?? ''}');
    phone = TextEditingController(
        text: '${club['receipt_phone'] ?? club['phone'] ?? ''}');
    footer = TextEditingController(
        text: '${club['receipt_footer'] ?? 'Спасибо за визит!'}');
    qr = TextEditingController(text: '${club['receipt_qr_url'] ?? ''}');
    caption = TextEditingController(
        text: '${club['receipt_qr_caption'] ?? 'Мы в соц. сетях'}');
    paper = (club['receipt_paper_mm'] as num?)?.toInt() ?? 58;
    enabled = club['receipt_qr_enabled'] != false;
    printCost = club['receipt_print_cost'] == true;
    logoUrl = club['logo_url'] as String?;
    fontTitle = (club['receipt_font_title'] as num?)?.toInt() ?? 30;
    fontTotal = (club['receipt_font_total'] as num?)?.toInt() ?? 20;
    fontMeta = (club['receipt_font_meta'] as num?)?.toInt() ?? 15;
    fontItems = (club['receipt_font_items'] as num?)?.toInt() ?? 15;
    fontFooter = (club['receipt_font_footer'] as num?)?.toInt() ?? 15;
    fontQrCaption = (club['receipt_font_qr_caption'] as num?)?.toInt() ?? 15;
  }

  @override
  void dispose() {
    name.dispose();
    subtitle.dispose();
    phone.dispose();
    footer.dispose();
    qr.dispose();
    caption.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: VCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('Chekdagi ma\'lumotlar',
                          style: TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 18)),
                      const SizedBox(height: 16),
                      _logoPicker(),
                      const SizedBox(height: 16),
                      _field(name, 'Chekdagi nomi',
                          hint: 'Bo\'sh bo\'lsa — klub nomi chop etiladi'),
                      _field(subtitle, 'Yuqoridagi qator',
                          hint: 'Nomi ostida chop etiladi — manzil yoki shior'),
                      _field(phone, 'Chekdagi telefon'),
                      _field(footer, 'Pastdagi qator',
                          hint: 'Oxirida chop etiladi — minnatdorchilik yoki shartlar'),
                      _field(qr, 'QR-koddagi havola',
                          hint: 'Instagram, Telegram yoki klub sayti'),
                      _field(caption, 'QR-kod ostidagi yozuv'),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('QR-kodni chop etish'),
                        value: enabled,
                        onChanged: (value) => setState(() => enabled = value),
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Tannarxni chop etish'),
                        subtitle: const Text(
                            'Har bir tovar tagida tannarxi ko\'rsatiladi',
                            style: TextStyle(fontSize: 12)),
                        value: printCost,
                        onChanged: (value) =>
                            setState(() => printCost = value),
                      ),
                      const SizedBox(height: 8),
                      const Text('Qog\'oz eni',
                          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
                      const SizedBox(height: 4),
                      Text(
                        'Termoprinteringizning rulon o\'lchamini tanlang — chekning eni va qatorlarning ko\'chirilishi shunga bog\'liq.',
                        style: TextStyle(color: VColors.muted, fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 58, label: Text('58 mm')),
                          ButtonSegment(value: 80, label: Text('80 mm')),
                        ],
                        selected: {paper},
                        onSelectionChanged: (value) =>
                            setState(() => paper = value.first),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                            onPressed: _save, child: const Text('Saqlash')),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 30),
              SizedBox(width: 420, child: _preview()),
            ],
          ),
          const SizedBox(height: 25),
          VCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Chekdagi shrift o\'lchami',
                    style:
                        TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
                Text('Piksellarda — o\'z printeringiz va ko\'zingizga moslang.',
                    style: TextStyle(color: VColors.muted, fontSize: 12)),
                const SizedBox(height: 6),
                _fontStepper('Muassasa nomi', fontTitle, (v) => setState(() => fontTitle = v)),
                _fontStepper('Yakuniy summa', fontTotal, (v) => setState(() => fontTotal = v)),
                _fontStepper('Chek ma\'lumotlari', fontMeta, (v) => setState(() => fontMeta = v)),
                _fontStepper('Buyurtma pozitsiyalari', fontItems, (v) => setState(() => fontItems = v)),
                _fontStepper('Pastdagi qator', fontFooter, (v) => setState(() => fontFooter = v)),
                _fontStepper('QR-kod ustidagi yozuv', fontQrCaption, (v) => setState(() => fontQrCaption = v)),
              ],
            ),
          ),
          const SizedBox(height: 25),
          PrinterSettingsSection(controller: widget.controller),
        ],
      );

  Widget _logoPicker() => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: VColors.field,
              borderRadius: BorderRadius.circular(12),
            ),
            clipBehavior: Clip.antiAlias,
            child: logoUrl == null || logoUrl!.isEmpty
                ? Icon(Icons.image_outlined, color: VColors.subtle)
                : Image.network(logoUrl!, fit: BoxFit.cover),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Chekdagi logotip',
                    style: TextStyle(color: VColors.subtle, fontSize: 13)),
                const SizedBox(height: 2),
                Text(
                  'PNG, chekning yuqorisida chop etiladi. Faqat ESC/POS chop etishda (USB/Bluetooth) — oddiy drayverli printerda rasm chop etilmaydi.',
                  style: TextStyle(color: VColors.subtle, fontSize: 12),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _uploadingLogo ? null : _pickLogo,
                  icon: _uploadingLogo
                      ? const SizedBox.square(
                          dimension: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.upload_rounded, size: 18),
                  label: const Text('PNG yuklash'),
                ),
              ],
            ),
          ),
        ],
      );

  Future<void> _pickLogo() async {
    try {
      final pickedPath = pickFileNative(title: 'Logotip tanlash', extensions: ['png']);
      if (pickedPath == null) return;
      setState(() => _uploadingLogo = true);
      final bytes = await File(pickedPath).readAsBytes();
      final clubId = widget.controller.context!.clubId;
      final path = '$clubId/receipt_logo.png';
      final storage = widget.controller.repository.client.storage.from('club-assets');
      await storage.uploadBinary(path, bytes,
          fileOptions: FileOptions(contentType: 'image/png', upsert: true));
      final url = storage.getPublicUrl(path);
      await widget.controller.repository.client
          .from('clubs')
          .update({'logo_url': url}).eq('id', clubId);
      setState(() => logoUrl = url);
      if (mounted) showDone(context, 'Logotip yuklandi');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _uploadingLogo = false);
    }
  }

  Widget _fontStepper(String label, int value, ValueChanged<int> onChanged) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: [
          Expanded(child: Text(label)),
          IconButton.outlined(
              onPressed: value > 8 ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove_rounded, size: 16)),
          SizedBox(
            width: 40,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
          IconButton.outlined(
              onPressed: value < 60 ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add_rounded, size: 16)),
          const SizedBox(width: 4),
          Text('piks.', style: TextStyle(color: VColors.subtle, fontSize: 12)),
        ]),
      );

  Widget _field(TextEditingController controller, String label, {String? hint}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: InputDecoration(labelText: label),
              onChanged: (_) => setState(() {}),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(hint, style: TextStyle(color: VColors.subtle, fontSize: 12)),
            ],
          ],
        ),
      );

  Widget _preview() => VCard(
        child: Column(
          children: [
            const Text('Chekni ko\'rib chiqish',
                style: TextStyle(fontWeight: FontWeight.w900, fontSize: 18)),
            const SizedBox(height: 20),
            Container(
              width: paper == 80 ? 400 : 320,
              color: _Paper.bg,
              padding: const EdgeInsets.all(22),
              child: Column(
                children: [
                  if (logoUrl != null && logoUrl!.isNotEmpty) ...[
                    Image.network(logoUrl!, height: 60),
                    const SizedBox(height: 10),
                  ],
                  Text(
                      name.text.trim().isEmpty
                          ? widget.controller.context!.clubName.toUpperCase()
                          : name.text.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _Paper.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: fontTitle.toDouble())),
                  if (subtitle.text.isNotEmpty)
                    Text(subtitle.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _Paper.muted, fontSize: fontMeta.toDouble())),
                  if (phone.text.isNotEmpty)
                    Text(phone.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _Paper.muted, fontSize: fontMeta.toDouble())),
                  const SizedBox(height: 10),
                  _dashedDivider(),
                  const SizedBox(height: 10),
                  _previewLine('Sana:', '20.09, 19:02'),
                  Text('Chek №42',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: _Paper.ink,
                          fontWeight: FontWeight.w900,
                          fontSize: fontMeta.toDouble())),
                  const SizedBox(height: 8),
                  _previewLine('Kassir:', 'Кассир'),
                  _previewLine('Joy:', 'Стол №2'),
                  _previewLine('O\'yin vaqti:', '1 ч 30 мин'),
                  const SizedBox(height: 10),
                  _dashedDivider(),
                  const SizedBox(height: 10),
                  _previewItem('1 × Бильярд (1 ч 30 мин)', '60 000'),
                  if (printCost)
                    _previewCost('12 000'),
                  _previewItem('2 × Coca-Cola 0.5л', '24 000'),
                  if (printCost)
                    _previewCost('9 000'),
                  _previewItem('1 × Чипсы', '15 000'),
                  if (printCost)
                    _previewCost('8 000'),
                  const SizedBox(height: 10),
                  _dashedDivider(),
                  const SizedBox(height: 10),
                  _previewItem('Oraliq summa', '99 000'),
                  _previewItem('Chegirma', '-9 000'),
                  const SizedBox(height: 4),
                  _previewItem('JAMI', '90 000 so\'m', bold: true, size: fontTotal.toDouble()),
                  _previewLine('To\'lov:', 'Наличные'),
                  const SizedBox(height: 10),
                  _dashedDivider(),
                  const SizedBox(height: 10),
                  if (footer.text.isNotEmpty)
                    Text(footer.text,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: _Paper.ink, fontSize: fontFooter.toDouble())),
                  if (enabled && qr.text.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _dashedDivider(),
                    const SizedBox(height: 12),
                    if (caption.text.isNotEmpty)
                      Text(caption.text,
                          style: TextStyle(color: _Paper.ink, fontSize: fontQrCaption.toDouble())),
                    const SizedBox(height: 10),
                    QrImageView(data: qr.text, size: 130),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _dashedDivider() => SizedBox(
        width: double.infinity,
        child: Text(
          '- ' * 24,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: TextStyle(color: _Paper.muted, fontSize: 12, height: 0.6),
        ),
      );

  Widget _previewLine(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: Row(children: [
          Text(label, style: TextStyle(color: _Paper.ink, fontSize: fontMeta.toDouble())),
          const SizedBox(width: 6),
          Expanded(
              child: Text(value,
                  style: TextStyle(color: _Paper.ink, fontSize: fontMeta.toDouble()))),
        ]),
      );

  Widget _previewCost(String amount) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text('  tannarx: $amount',
            style: TextStyle(color: _Paper.muted, fontSize: 12)),
      );

  Widget _previewItem(String label, String amount, {bool bold = false, double? size}) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(
              child: Text(label,
                  style: TextStyle(
                      color: _Paper.ink,
                      fontSize: size ?? fontItems.toDouble(),
                      fontWeight: bold ? FontWeight.w900 : FontWeight.normal))),
          Text(amount,
              style: TextStyle(
                  color: _Paper.ink,
                  fontSize: size ?? fontItems.toDouble(),
                  fontWeight: bold ? FontWeight.w900 : FontWeight.normal)),
        ]),
      );

  Future<void> _save() async {
    try {
      await widget.controller.repository.client.from('clubs').update({
        'receipt_header': name.text,
        'receipt_subtitle': subtitle.text,
        'receipt_phone': phone.text,
        'receipt_footer': footer.text,
        'receipt_qr_url': qr.text.isEmpty ? null : qr.text,
        'receipt_qr_caption': caption.text,
        'receipt_qr_enabled': enabled,
        'receipt_print_cost': printCost,
        'receipt_paper_mm': paper,
        'receipt_font_title': fontTitle,
        'receipt_font_total': fontTotal,
        'receipt_font_meta': fontMeta,
        'receipt_font_items': fontItems,
        'receipt_font_footer': fontFooter,
        'receipt_font_qr_caption': fontQrCaption,
      }).eq('id', widget.controller.context!.clubId);
      await widget.controller.reloadContext();
      if (mounted) showDone(context, 'Sozlamalar saqlandi');
    } catch (error) {
      if (mounted) showError(context, error);
    }
  }
}

/// Opens the same printer picker shown at the bottom of Sozlamalar → Chek as
/// a standalone dialog — used by the top-bar print icon so a cashier doesn't
/// have to hunt through settings tabs to configure this machine's printer.
Future<void> showPrinterSettingsDialog(
    BuildContext context, ClubController controller) {
  return showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: PrinterSettingsSection(
            controller: controller,
            embedded: false,
          ),
        ),
      ),
    ),
  );
}

/// The printer picker itself: transport (Windows / USB / Bluetooth), the
/// matching device list, and a test-print button. Self-contained — loads and
/// saves its own [PrinterConfig] — so it can be dropped into Sozlamalar →
/// Chek or opened directly as a dialog from the top bar.
class PrinterSettingsSection extends StatefulWidget {
  const PrinterSettingsSection(
      {super.key, required this.controller, this.embedded = true});
  final ClubController controller;

  /// true when placed inline inside another card-bearing page (Sozlamalar),
  /// false when it needs to draw its own title/close button as a dialog.
  final bool embedded;

  @override
  State<PrinterSettingsSection> createState() =>
      _PrinterSettingsSectionState();
}

class _PrinterSettingsSectionState extends State<PrinterSettingsSection> {
  PrinterConfig? printer;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    PrinterConfig.load().then((c) {
      if (mounted) setState(() => printer = c);
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = printer;
    final body = p == null
        ? const SizedBox(height: 120, child: LoadingPane())
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.embedded)
                const Text('Shu kassa printeri',
                    style:
                        TextStyle(fontWeight: FontWeight.w900, fontSize: 18))
              else
                Row(children: [
                  const Expanded(
                    child: Text('Shu kassa printeri',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 18)),
                  ),
                  IconButton(
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded)),
                ]),
              const SizedBox(height: 4),
              Text(
                'Ushbu sozlama faqat shu kompyuterga tegishli — har bir kassa o\'z printerini alohida tanlaydi.',
                style: TextStyle(color: VColors.muted, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SegmentedButton<PrinterTransport>(
                segments: const [
                  ButtonSegment(
                      value: PrinterTransport.windows,
                      label: Text('Windows printeri')),
                  ButtonSegment(
                      value: PrinterTransport.usb, label: Text('USB-kabel')),
                  ButtonSegment(
                      value: PrinterTransport.bluetooth,
                      label: Text('Bluetooth')),
                ],
                selected: {p.transport},
                onSelectionChanged: (v) =>
                    setState(() => p.transport = v.first),
              ),
              const SizedBox(height: 14),
              if (p.transport == PrinterTransport.windows)
                _windowsPrinterPicker(p)
              else
                _serialPortPicker(p),
              const SizedBox(height: 14),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Chekni ekranda ham ko\'rsatish'),
                value: p.showOnScreen,
                onChanged: (v) => setState(() => p.showOnScreen = v),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () async {
                      await p.save();
                      if (context.mounted) {
                        showDone(context, 'Printer sozlamalari saqlandi');
                      }
                    },
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Saqlash'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _testing ? null : () => _testPrint(p),
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.receipt_outlined),
                    label: const Text('Sinov chek'),
                  ),
                ),
              ]),
            ],
          );
    return widget.embedded
        ? VCard(child: body)
        : Padding(padding: const EdgeInsets.all(20), child: body);
  }

  Widget _windowsPrinterPicker(PrinterConfig p) {
    final names = PrinterService.listWindowsPrinters();
    return Row(children: [
      Expanded(
        child: DropdownButtonFormField<String>(
          initialValue: names.contains(p.windowsPrinterName)
              ? p.windowsPrinterName
              : null,
          decoration: const InputDecoration(labelText: 'Windows printeri'),
          items: names
              .map((n) => DropdownMenuItem(value: n, child: Text(n)))
              .toList(),
          onChanged: (v) => setState(() => p.windowsPrinterName = v),
        ),
      ),
      const SizedBox(width: 8),
      IconButton(
        tooltip: 'Ro\'yxatni yangilash',
        onPressed: () => setState(() {}),
        icon: const Icon(Icons.refresh_rounded),
      ),
    ]);
  }

  Widget _serialPortPicker(PrinterConfig p) {
    final ports = PrinterService.listSerialPorts();
    return Column(children: [
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: ports.contains(p.serialPort) ? p.serialPort : null,
            decoration: const InputDecoration(labelText: 'COM-port'),
            items: ports
                .map((n) => DropdownMenuItem(value: n, child: Text(n)))
                .toList(),
            onChanged: (v) => setState(() => p.serialPort = v),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: 'Ro\'yxatni yangilash',
          onPressed: () => setState(() {}),
          icon: const Icon(Icons.refresh_rounded),
        ),
      ]),
      const SizedBox(height: 10),
      TextField(
        keyboardType: TextInputType.number,
        controller: TextEditingController(text: '${p.baudRate}'),
        decoration: const InputDecoration(labelText: 'Baud rate'),
        onChanged: (v) => p.baudRate = int.tryParse(v) ?? p.baudRate,
      ),
    ]);
  }

  Future<void> _testPrint(PrinterConfig p) async {
    setState(() => _testing = true);
    try {
      final bytes = buildOrderReceipt(
        club: widget.controller.context!.club,
        cashierName: widget.controller.context!.userName,
        receiptNumber: 0,
        date: DateTime.now(),
        items: const [
          ReceiptLine('Sinov mahsuloti', 10000, quantity: 1),
        ],
        total: 10000,
        paymentMethodName: 'Sinov',
      );
      await PrinterService.print(p, bytes);
      if (mounted) showDone(context, 'Sinov cheki yuborildi');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }
}

class _TelegramBotSettings extends StatefulWidget {
  const _TelegramBotSettings({required this.controller});
  final ClubController controller;

  @override
  State<_TelegramBotSettings> createState() => _TelegramBotSettingsState();
}

class _TelegramBotSettingsState extends State<_TelegramBotSettings> {
  final _token = TextEditingController();
  bool _busy = false;
  // Stored instead of called inline in build(): a FutureBuilder whose
  // `future` is created fresh on every build resets to the loading state on
  // *any* rebuild (an unrelated setState higher up, a tab switch back to
  // this pane), flashing this whole card back to a spinner even though
  // nothing about the bot connection actually changed. Only reassigned when
  // a connect/disconnect actually needs a fresh read.
  late Future<Map<String, dynamic>> _future = _load();

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _load() => widget.controller.repository.client
      .rpc('club_bot_info',
          params: {'p_club_id': widget.controller.context!.clubId})
      .then(rowMap);

  @override
  Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const LoadingPane();
          final info = snapshot.data!;
          final connected =
              info['configured'] == true && info['active'] == true;
          final adminPaired = info['owner_paired'] == true;
          return ListView(
            children: [
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        const Text('Klub telegram-boti',
                            style: TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 19)),
                        const Spacer(),
                        Pill(connected ? 'ulangan' : 'ulanmagan',
                            color: connected ? null : VColors.field,
                            foreground: connected ? null : VColors.muted),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Mehmonlar bo\'sh joylarni ko\'radi, band qiladi va bonus to\'playdi. '
                      'Administratorlar tushumni, zal xaritasini va bronlarni ko\'radi — mijozlar bu tugmalarni ko\'rmaydi.',
                      style: TextStyle(color: VColors.subtle),
                    ),
                    if (connected) ...[
                      const Divider(height: 30),
                      _kv('Birinchi bo\'lib «Start» tugmasini bosgan',
                          'administrator bo\'ladi'),
                      const SizedBox(height: 8),
                      _kv('Administrator ulangan', adminPaired ? 'ha' : 'yo\'q'),
                      const SizedBox(height: 18),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: _busy ? null : () => _disconnect(context),
                          icon: Icon(Icons.link_off_rounded, color: VColors.red),
                          label: Text('Botni o\'chirish',
                              style: TextStyle(color: VColors.red)),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
              VCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Botni almashtirish',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 18)),
                    const SizedBox(height: 14),
                    _step(1, 'Telegramda @BotFather\'ni oching va /newbot yuboring'),
                    const SizedBox(height: 10),
                    _step(2, 'Nom o\'ylab toping — masalan «Angren klubi»'),
                    const SizedBox(height: 10),
                    _step(3,
                        'BotFather tokenni yuboradi — uni shu yerga nusxalang'),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _token,
                      enabled: !_busy,
                      decoration: const InputDecoration(hintText: 'Bot tokeni'),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _connect(context),
                        icon: _busy
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded),
                        label: const Text('Ulash'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      );

  Widget _kv(String label, String value) => Row(
        children: [
          Expanded(child: Text(label, style: TextStyle(color: VColors.muted))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ],
      );

  Widget _step(int n, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: VColors.field,
              shape: BoxShape.circle,
            ),
            child: Text('$n',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: VColors.muted)),
          ),
          const SizedBox(width: 12),
          Expanded(child: Text(text)),
        ],
      );

  Future<void> _connect(BuildContext context) async {
    final token = _token.text.trim();
    if (!RegExp(r'^\d+:[\w-]{20,}$').hasMatch(token)) {
      showError(context, 'Bu bot tokeniga o\'xshamaydi — BotFather\'dan olingan tokenni to\'liq nusxalang.');
      return;
    }
    setState(() => _busy = true);
    try {
      final meRes =
          await http.get(Uri.parse('https://api.telegram.org/bot$token/getMe'));
      final me = jsonDecode(meRes.body) as Map<String, dynamic>;
      if (me['ok'] != true) {
        throw Exception('Telegram tokenni tasdiqlamadi. Tokenni tekshirib qaytadan urining.');
      }
      final username = (me['result'] as Map)['username'] as String?;

      final reg = await widget.controller.repository.client.rpc('set_club_bot',
          params: {
            'p_club_id': widget.controller.context!.clubId,
            'p_bot_token': token,
            'p_username': username,
          });
      final secret = rowMap(reg)['webhook_secret'] as String;

      final hookRes = await http.post(
        Uri.parse('https://api.telegram.org/bot$token/setWebhook'),
        headers: {'content-type': 'application/json'},
        // The bot runs as a persistent service on Railway; the old Supabase
        // edge function of the same name is a stale copy without the
        // receipts, ratings or speed-ups.
        body: jsonEncode({
          'url': 'https://club-bot-production.up.railway.app/club-bot?s=$secret',
          'allowed_updates': ['message', 'callback_query'],
        }),
      );
      final hook = jsonDecode(hookRes.body) as Map<String, dynamic>;
      if (hook['ok'] != true) {
        throw Exception('Bot saqlandi, lekin webhook o\'rnatilmadi. Qaytadan urining.');
      }

      _token.clear();
      if (context.mounted) showDone(context, 'Bot ulandi: @$username');
      setState(() => _future = _load());
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Botni o\'chirish'),
        content: const Text(
            'Bot o\'chiriladi — mijozlar va administratorlar undan foydalana olmaydi. Keyinroq yana ulash mumkin.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Bekor qilish')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: VColors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('O\'chirish')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await widget.controller.repository.client.rpc('disable_club_bot',
          params: {'p_club_id': widget.controller.context!.clubId});
      setState(() => _future = _load());
    } catch (e) {
      if (context.mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ResourceRow extends StatelessWidget {
  const _ResourceRow({
    required this.row,
    required this.relays,
    required this.controller,
    required this.onEdit,
  });

  final Map<String, dynamic> row;
  final List<Map<String, dynamic>> relays;
  final ClubController controller;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final type = row['resource_types'];
    final typeName = type is Map ? '${type['name']}' : '';
    final zoneName = '${row['zone'] ?? ''}'.trim();
    final tariff = row['tariffs'];
    final priceLabel = tariff is Map
        ? '${tariff['name']} · ${money(tariff['price_per_hour'])}/soat'
        : '—';
    final relay = relays.firstWhere(
        (r) => '${r['id']}' == '${row['relay_device_id']}',
        orElse: () => const {});
    final channelLabel =
        row['relay_channel'] != null ? 'Kanal ${row['relay_channel']}' : '—';

    return VCard(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${row['name']}',
                  style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
              Text(typeName,
                  style: TextStyle(color: VColors.subtle, fontSize: 12.5)),
            ],
          ),
        ),
        Expanded(
            flex: 2,
            child: Text(zoneName.isEmpty ? '—' : zoneName,
                style: TextStyle(color: VColors.muted, fontSize: 13))),
        Expanded(
            flex: 3,
            child:
                Text(priceLabel, style: TextStyle(color: VColors.muted, fontSize: 13))),
        Expanded(
            flex: 2,
            child: Text(channelLabel,
                style: TextStyle(color: VColors.subtle, fontSize: 13))),
        if (relay.isNotEmpty)
          IconButton(
            tooltip: 'Releni sinash',
            icon: const Icon(Icons.settings_remote_outlined, size: 17),
            onPressed: () async {
              try {
                await controller.repository
                    .relayCommand('${row['id']}', true);
                if (context.mounted) showDone(context, 'Yoqildi');
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
          ),
        _VSwitch(
          value: row['active'] != false,
          onChanged: (value) async {
            await controller.repository.client
                .from('resources')
                .update({'active': value}).eq('id', row['id']);
            controller.refresh();
          },
        ),
        const SizedBox(width: 4),
        IconButton(
          icon: Icon(Icons.delete_outline_rounded, size: 19, color: VColors.red),
          onPressed: () async {
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (c) => AlertDialog(
                title: const Text('Joyni o\'chirish'),
                content: Text('${row['name']} butunlay o\'chiriladi.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(c, false),
                      child: const Text('Bekor qilish')),
                  FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: VColors.red),
                      onPressed: () => Navigator.pop(c, true),
                      child: const Text('O\'chirish')),
                ],
              ),
            );
            if (confirmed != true) return;
            await controller.repository.client
                .from('resources')
                .delete()
                .eq('id', row['id']);
            controller.refresh();
          },
        ),
        IconButton(
            icon: const Icon(Icons.edit_outlined, size: 19), onPressed: onEdit),
      ]),
    );
  }
}

class _VSwitch extends StatelessWidget {
  const _VSwitch({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: () => onChanged(!value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 40,
          height: 23,
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: value ? VColors.green : VColors.field,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: value ? VColors.green : VColors.line, width: 1),
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 15,
              height: 15,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: value ? const Color(0xFF0B2B21) : VColors.subtle,
              ),
            ),
          ),
        ),
      );
}

class _CategoryPill extends StatelessWidget {
  const _CategoryPill({required this.label, required this.onDelete});
  final String label;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: VColors.field,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: VColors.line),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: TextStyle(
                    color: VColors.ink,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 8),
            InkWell(
              onTap: onDelete,
              child: Icon(Icons.close_rounded, size: 14, color: VColors.muted),
            ),
          ],
        ),
      );
}

class _AddCategoryPill extends StatelessWidget {
  const _AddCategoryPill({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: VColors.field,
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: VColors.line),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 15, color: VColors.green),
              const SizedBox(width: 5),
              Text('Kategoriya qo\'shish',
                  style: TextStyle(
                      color: VColors.green,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      );
}
