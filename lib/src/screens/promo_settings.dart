import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/promo.dart';

/// Settings → "Aksiya": the "6 visits = 1 free hour" promo — on/off, its
/// rules, and how it is doing this month.
class PromoSettings extends StatefulWidget {
  const PromoSettings({super.key, required this.controller});

  final ClubController controller;

  @override
  State<PromoSettings> createState() => _PromoSettingsState();
}

class _PromoSettingsState extends State<PromoSettings> {
  late Future<List<Map<String, dynamic>?>> _future = _load();
  bool _busy = false;
  final _visits = TextEditingController();
  final _amount = TextEditingController();
  final _minutes = TextEditingController();
  final _free = TextEditingController();
  final _days = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();
  DateTime? _ends;
  bool _filled = false;

  String get _clubId => widget.controller.context!.clubId;

  Future<List<Map<String, dynamic>?>> _load() async {
    final repo = widget.controller.repository;
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    final results = await Future.wait([
      repo.promoSettings(_clubId),
      repo.promoStats(_clubId, month, DateTime(now.year, now.month + 1)),
    ]);
    return results;
  }

  @override
  void dispose() {
    for (final c in [_visits, _amount, _minutes, _free, _days, _from, _to]) {
      c.dispose();
    }
    super.dispose();
  }

  void _fill(Map<String, dynamic>? s) {
    if (_filled) return;
    _filled = true;
    _visits.text = '${s?['visits_needed'] ?? 6}';
    _amount.text = '${s?['min_amount'] ?? 60000}';
    _minutes.text = '${s?['min_minutes'] ?? 60}';
    _free.text = '${s?['free_minutes'] ?? 60}';
    _days.text = '${s?['valid_days'] ?? 7}';
    _from.text = '${s?['hour_from'] ?? 11}';
    _to.text = '${s?['hour_to'] ?? 17}';
    _ends = DateTime.tryParse('${s?['ends_at']}')?.toLocal();
  }

  Future<void> _save({bool? enabled}) async {
    setState(() => _busy = true);
    try {
      await widget.controller.repository.savePromoSettings(_clubId, {
        if (enabled != null) 'enabled': enabled,
        'visits_needed': int.tryParse(_visits.text) ?? 6,
        'min_amount':
            int.tryParse(_amount.text.replaceAll(RegExp(r'\D'), '')) ?? 60000,
        'min_minutes': int.tryParse(_minutes.text) ?? 60,
        'free_minutes': int.tryParse(_free.text) ?? 60,
        'valid_days': int.tryParse(_days.text) ?? 7,
        'hour_from': int.tryParse(_from.text) ?? 11,
        'hour_to': int.tryParse(_to.text) ?? 17,
        'ends_at': _ends?.toUtc().toIso8601String(),
      });
      if (mounted) {
        showDone(context, tr('Saqlandi'));
        setState(() => _future = _load());
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String label, TextEditingController c, {String? suffix}) =>
      SizedBox(
        width: 190,
        child: TextField(
          controller: c,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: tr(label), suffixText: suffix),
        ),
      );

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<List<Map<String, dynamic>?>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(child: Text('${snap.error}'));
          }
          if (!snap.hasData) return const LoadingPane();
          final settings = snap.data![0];
          final stats = snap.data![1];
          _fill(settings);
          final enabled = settings?['enabled'] == true;
          final ended = _ends != null && _ends!.isBefore(DateTime.now());
          return ListView(children: [
            VCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Text('🎱', style: TextStyle(fontSize: 22)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(tr('Aksiya: 6 tashrif = 1 soat bepul'),
                          style: const TextStyle(
                              fontWeight: FontWeight.w900, fontSize: 17)),
                    ),
                    Switch(
                      value: enabled,
                      onChanged: _busy ? null : (v) => _save(enabled: v),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Text(
                    tr('Mijoz kerakli tashriflarni to\'plasa, botga bepul o\'yin kuponi keladi. Faqat yoqilgandan keyingi tashriflar hisoblanadi.'),
                    style: TextStyle(color: VColors.muted),
                  ),
                  if (ended) ...[
                    const SizedBox(height: 6),
                    Text(tr('Aksiya muddati tugagan'),
                        style: TextStyle(
                            color: VColors.red, fontWeight: FontWeight.w800)),
                  ],
                  const SizedBox(height: 16),
                  Wrap(spacing: 14, runSpacing: 14, children: [
                    _field('Tashriflar soni', _visits),
                    _field('Chek kamida', _amount, suffix: 'so\'m'),
                    _field('O\'yin kamida', _minutes, suffix: tr('daq')),
                    _field('Bepul vaqt', _free, suffix: tr('daq')),
                    _field('Kupon muddati', _days, suffix: tr('kun')),
                    _field('Soatdan', _from),
                    _field('Soatgacha', _to),
                  ]),
                  const SizedBox(height: 14),
                  Row(children: [
                    Text('${tr('Aksiya tugashi')}: ',
                        style: TextStyle(color: VColors.muted)),
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _ends ?? DateTime(2026, 12, 1),
                                firstDate: DateTime(2025),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) {
                                setState(() => _ends = picked);
                              }
                            },
                      child: Text(_ends == null
                          ? tr('muddatsiz')
                          : DateFormat('dd.MM.yyyy').format(_ends!)),
                    ),
                    if (_ends != null)
                      IconButton(
                        tooltip: tr('muddatsiz'),
                        onPressed: () => setState(() => _ends = null),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    const Spacer(),
                    FilledButton(
                      onPressed: _busy ? null : () => _save(),
                      child: Text(tr('Saqlash')),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 14),
            VCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tr('Shu oy'),
                      style: const TextStyle(
                          fontWeight: FontWeight.w900, fontSize: 16)),
                  const SizedBox(height: 12),
                  Wrap(spacing: 12, runSpacing: 12, children: [
                    _Stat(tr('Hisoblangan tashriflar'),
                        '${stats?['visits'] ?? 0}'),
                    _Stat(tr('Berilgan kuponlar'), '${stats?['issued'] ?? 0}'),
                    _Stat(tr('Ishlatilgan'), '${stats?['used'] ?? 0}'),
                    _Stat(tr('Bepul berilgan'),
                        money(stats?['used_amount'] ?? 0)),
                    _Stat(tr('Kuygan'), '${stats?['expired'] ?? 0}'),
                    _Stat(tr('Hozir faol'), '${stats?['active'] ?? 0}',
                        gold: true),
                  ]),
                ],
              ),
            ),
          ]);
        },
      );
}

class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.gold = false});

  final String label;
  final String value;
  final bool gold;

  @override
  Widget build(BuildContext context) => Container(
        width: 170,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: VColors.field,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: gold ? promoGold : VColors.line),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 20,
                    color: gold ? promoGold : VColors.ink)),
            const SizedBox(height: 4),
            Text(label, style: TextStyle(color: VColors.muted, fontSize: 12.5)),
          ],
        ),
      );
}
