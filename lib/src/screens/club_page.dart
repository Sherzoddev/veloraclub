import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';
import '../widgets/customer_picker.dart';
import 'session_payment_dialog.dart';
import 'session_products_page.dart';

class ClubPage extends StatefulWidget {
  const ClubPage({super.key, required this.controller});
  final ClubController controller;

  @override
  State<ClubPage> createState() => _ClubPageState();
}

class _ClubPageState extends State<ClubPage> {
  String family = 'ALL';

  Future<List<dynamic>> load() async {
    final repo = widget.controller.repository;
    final clubId = widget.controller.context!.clubId;
    return Future.wait([
      repo.resources(clubId),
      repo.activeSessions(clubId),
      repo.tariffs(clubId),
      repo.customers(clubId),
      repo.reservations(clubId),
    ]);
  }

  static const _familyLabels = {
    'PLAYSTATION': 'PlayStation',
    'BILLIARD': 'Bilyard',
  };

  String _familyLabel(String family) =>
      _familyLabels[family] ??
      (family.isEmpty ? family : family[0] + family.substring(1).toLowerCase());

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: pagePadding(context),
      child: AsyncPane<List<dynamic>>(
        future: load(),
        builder: (context, values) {
          final resources = List<Map<String, dynamic>>.from(values[0])
            ..sort((a, b) {
              final an =
                  (a['sort_order'] as num?) ?? (a['number'] as num?) ?? 0;
              final bn =
                  (b['sort_order'] as num?) ?? (b['number'] as num?) ?? 0;
              return an.compareTo(bn);
            });
          final sessions = values[1] as List<Map<String, dynamic>>;
          final tariffs = values[2] as List<Map<String, dynamic>>;
          final customers = values[3] as List<Map<String, dynamic>>;
          final sessionByResource = {
            for (final session in sessions) '${session['resource_id']}': session
          };
          final reservations = values[4] as List<Map<String, dynamic>>;
          final reservationByResource = <String, Map<String, dynamic>>{};
          for (final r in reservations) {
            if (r['status'] != 'pending') continue;
            reservationByResource.putIfAbsent('${r['resource_id']}', () => r);
          }
          final families = <String>{
            for (final r in resources)
              if (r['resource_types'] is Map) '${r['resource_types']['family']}'
          }.toList()
            ..sort();
          final filtered = resources.where((r) {
            if (family == 'ALL') return true;
            final type = r['resource_types'];
            return type is Map && '${type['family']}' == family;
          }).toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              PageHeader(
                title: tr('Zal xaritasi'),
                subtitle: resources.isEmpty
                    ? null
                    : (LocaleController.instance.isRu
                        ? 'Занято ${sessions.length} из ${resources.length}'
                        : '${resources.length} tadan ${sessions.length} ta band'),
                actions: [
                  OutlinedButton.icon(
                    onPressed: widget.controller.refresh,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: Text(tr('Yangilash')),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: VColors.field,
                      foregroundColor: VColors.ink,
                      minimumSize: const Size(0, 36),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      side: BorderSide(color: VColors.line),
                      textStyle: appFont(const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w700)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 8,
                children: [
                  _Filter('ALL', tr('Barchasi'), family,
                      (v) => setState(() => family = v)),
                  for (final f in families)
                    _Filter(f, tr(_familyLabel(f)), family,
                        (v) => setState(() => family = v)),
                ],
              ),
              const SizedBox(height: 20),
              Expanded(
                child: filtered.isEmpty
                    ? EmptyState(
                        icon: Icons.grid_view_rounded,
                        title: tr('Joylar topilmadi'),
                        subtitle: tr("Sozlamalarda yangi joy qo'shing"),
                      )
                    : LayoutBuilder(builder: (context, box) {
                        // As many ~300px cards per row as fit, stretched to
                        // fill it; one full-width card on a phone.
                        const gap = 14.0;
                        final cols = ((box.maxWidth + gap) / (286 + gap))
                            .floor()
                            .clamp(1, 12);
                        final cardWidth =
                            ((box.maxWidth - gap * (cols - 1)) / cols)
                                .clamp(0.0, 360.0);
                        return SingleChildScrollView(
                          child: Wrap(
                            spacing: 14,
                            runSpacing: 14,
                            children: filtered.map((resource) {
                              final session =
                                  sessionByResource['${resource['id']}'];
                              final reservation =
                                  reservationByResource['${resource['id']}'];
                              // At least 300 tall like before, taller when a
                              // card has more to show (prepaid timer, bigger
                              // system font) instead of clipping it.
                              return SizedBox(
                                width: cardWidth,
                                child: ConstrainedBox(
                                  constraints:
                                      const BoxConstraints(minHeight: 300),
                                  child: IntrinsicHeight(
                                    child: _ResourceCard(
                                      resource: resource,
                                      session: session,
                                      reservation: reservation,
                                      tariffs: tariffs,
                                      customers: customers,
                                      allResources: resources,
                                      sessionByResource: sessionByResource,
                                      controller: widget.controller,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        );
                      }),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Filter extends StatelessWidget {
  const _Filter(this.value, this.label, this.current, this.changed);
  final String value;
  final String label;
  final String current;
  final ValueChanged<String> changed;

  @override
  Widget build(BuildContext context) {
    final selected = value == current;
    return OutlinedButton(
      onPressed: () => changed(value),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected ? VColors.green : VColors.field,
        foregroundColor: selected ? Colors.black87 : VColors.muted,
        side: BorderSide(color: selected ? VColors.green : VColors.line),
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        textStyle:
            appFont(const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (selected) ...[
            const Icon(Icons.check_rounded, size: 15),
            const SizedBox(width: 5),
          ],
          Text(label),
        ],
      ),
    );
  }
}

/// Live-ticking pill/timer/amount/actions shown on an occupied table card.
/// Runs its own 1s timer purely to animate the elapsed-time text and a
/// client-side per-hour estimate of the amount; the authoritative charge is
/// always recomputed server-side (`session_current_charge`) when the
/// session dialog or payment sheet opens.
class _ActiveBody extends StatefulWidget {
  const _ActiveBody({
    required this.session,
    required this.tariff,
    required this.familyLabel,
    required this.onPause,
    required this.onResume,
    required this.onRound,
    required this.onTimeUp,
  });

  final Map<String, dynamic> session;
  final Map<String, dynamic>? tariff;
  final String familyLabel;
  final VoidCallback onPause;
  final VoidCallback onResume;
  final VoidCallback onRound;
  final VoidCallback onTimeUp;

  @override
  State<_ActiveBody> createState() => _ActiveBodyState();
}

class _ActiveBodyState extends State<_ActiveBody> {
  Timer? _timer;
  bool _timeUpShown = false;

  @override
  void initState() {
    super.initState();
    if (!_paused) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(_checkTimeUp);
      });
    }
  }

  @override
  void didUpdateWidget(_ActiveBody old) {
    super.didUpdateWidget(old);
    if (old.session['planned_end_at'] != widget.session['planned_end_at']) {
      _timeUpShown = false;
    }
  }

  void _checkTimeUp() {
    final end = _plannedEnd;
    if (!_timeUpShown && end != null && DateTime.now().isAfter(end)) {
      _timeUpShown = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onTimeUp();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  bool get _paused => widget.session['status'] == 'PAUSED';

  int get _elapsedSeconds {
    final started = DateTime.tryParse('${widget.session['started_at']}');
    if (started == null) return 0;
    var seconds = DateTime.now().toUtc().difference(started.toUtc()).inSeconds;
    seconds -= (widget.session['paused_seconds'] as num?)?.toInt() ?? 0;
    if (_paused) {
      final pausedAt =
          DateTime.tryParse('${widget.session['pause_started_at']}');
      if (pausedAt != null) {
        seconds -=
            DateTime.now().toUtc().difference(pausedAt.toUtc()).inSeconds;
      }
    }
    return seconds < 0 ? 0 : seconds;
  }

  String get _hms {
    final s = _elapsedSeconds;
    final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  int get _amount {
    final pricePerHour = (widget.tariff?['price_per_hour'] as num?) ?? 0;
    final banked = (widget.session['banked_time_amount'] as num?)?.toInt() ?? 0;
    final segment = (pricePerHour * _elapsedSeconds / 3600).round();
    return banked + segment;
  }

  String get _clock {
    final d = DateTime.tryParse('${widget.session['started_at']}')?.toLocal();
    if (d == null) return '';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  DateTime? get _plannedEnd =>
      DateTime.tryParse('${widget.session['planned_end_at']}')?.toLocal();

  @override
  Widget build(BuildContext context) {
    final customer = widget.session['customers'];
    final round = (widget.session['round_number'] as num?)?.toInt() ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusPill(
          label: tr(_paused ? 'PAUZA' : 'O\'YIN BORMOQDA'),
          background: _paused
              ? VColors.orange.withValues(alpha: .16)
              : VColors.greenSoft,
          foreground: _paused ? VColors.orange : VColors.green,
        ),
        if (customer is Map) ...[
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.person_outline_rounded, size: 14, color: VColors.muted),
            const SizedBox(width: 4),
            Flexible(
              child: Text('${customer['full_name'] ?? ''}',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: VColors.muted, fontSize: 13)),
            ),
          ]),
        ],
        const Spacer(),
        Row(children: [
          Text(LocaleController.instance.isRu ? 'с $_clock' : '$_clock dan',
              style: TextStyle(color: VColors.subtle, fontSize: 12)),
          const SizedBox(width: 8),
          _StatusPill(
              label: LocaleController.instance.isRu
                  ? 'РАУНД $round'
                  : 'RAUND $round',
              background: VColors.greenSoft,
              foreground: VColors.green,
              small: true),
        ]),
        const SizedBox(height: 6),
        Text(_hms,
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 26)),
        const SizedBox(height: 2),
        Text(money(_amount),
            style: TextStyle(
                color: VColors.green,
                fontSize: 18,
                fontWeight: FontWeight.w900)),
        if (_plannedEnd != null) ...[
          const SizedBox(height: 2),
          Builder(builder: (context) {
            final remaining = _plannedEnd!.difference(DateTime.now()).inSeconds;
            final soon = remaining <= 300;
            return Row(children: [
              Icon(Icons.timer_outlined,
                  size: 13, color: soon ? VColors.red : VColors.subtle),
              const SizedBox(width: 3),
              Text(
                  LocaleController.instance.isRu
                      ? 'до ${_plannedEnd!.hour.toString().padLeft(2, '0')}:${_plannedEnd!.minute.toString().padLeft(2, '0')}'
                      : '${_plannedEnd!.hour.toString().padLeft(2, '0')}:${_plannedEnd!.minute.toString().padLeft(2, '0')} gacha',
                  style: TextStyle(
                      color: soon ? VColors.red : VColors.subtle,
                      fontSize: 12,
                      fontWeight: FontWeight.w700)),
            ]);
          }),
        ],
        if (widget.familyLabel.isNotEmpty)
          Text(tr(widget.familyLabel),
              style: TextStyle(color: VColors.subtle, fontSize: 13)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _paused ? widget.onResume : widget.onPause,
              icon: Icon(
                  _paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
                  size: 19),
              label: Text(tr(_paused ? 'Davom' : 'Pauza')),
              style: OutlinedButton.styleFrom(
                backgroundColor: VColors.field,
                foregroundColor: VColors.ink,
                side: BorderSide(color: VColors.line),
                minimumSize: const Size(0, 46),
                textStyle: appFont(
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: widget.onRound,
              icon: const Icon(Icons.replay_rounded, size: 19),
              label: Text(tr('Raund')),
              style: OutlinedButton.styleFrom(
                backgroundColor: VColors.field,
                foregroundColor: VColors.green,
                side: BorderSide(color: VColors.green),
                minimumSize: const Size(0, 46),
                textStyle: appFont(
                    const TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
              ),
            ),
          ),
        ]),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.label,
    required this.background,
    required this.foreground,
    this.small = false,
  });

  final String label;
  final Color background;
  final Color foreground;
  final bool small;

  @override
  Widget build(BuildContext context) => Container(
        padding: EdgeInsets.symmetric(
            horizontal: small ? 8 : 10, vertical: small ? 3 : 5),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(7),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration:
                  BoxDecoration(color: foreground, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    color: foreground,
                    fontWeight: FontWeight.w800,
                    fontSize: small ? 10 : 11)),
          ],
        ),
      );
}

class _AmountStat extends StatelessWidget {
  const _AmountStat({required this.label, required this.value});
  final String label;
  final int value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: VColors.subtle, fontSize: 11)),
          const SizedBox(height: 2),
          Text(money(value),
              style: TextStyle(
                  color: VColors.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 14)),
        ],
      );
}

String _clockOf(dynamic iso) {
  final d = DateTime.tryParse('$iso')?.toLocal();
  if (d == null) return '';
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

class _ResourceCard extends StatelessWidget {
  const _ResourceCard({
    required this.resource,
    required this.session,
    this.reservation,
    required this.tariffs,
    required this.customers,
    required this.allResources,
    required this.sessionByResource,
    required this.controller,
  });

  final Map<String, dynamic> resource;
  final Map<String, dynamic>? session;
  final Map<String, dynamic>? reservation;
  final List<Map<String, dynamic>> tariffs;
  final List<Map<String, dynamic>> customers;
  final List<Map<String, dynamic>> allResources;
  final Map<String, Map<String, dynamic>> sessionByResource;
  final ClubController controller;

  num? get _pricePerHour {
    final tariff = resource['tariffs'];
    return tariff is Map ? tariff['price_per_hour'] as num? : null;
  }

  String get _familyLabel => resource['resource_types'] is Map
      ? (resource['resource_types']['family'] == 'BILLIARD'
          ? 'Bilyard'
          : resource['resource_types']['family'] == 'PLAYSTATION'
              ? 'PlayStation'
              : '')
      : '';

  @override
  Widget build(BuildContext context) {
    final active = session != null;
    final databaseBusy = const {
      'STARTING',
      'ACTIVE',
      'PAUSED',
      'STOPPING',
    }.contains('${resource['status']}');
    final syncing = !active && databaseBusy;
    final paused = active && session!['status'] == 'PAUSED';
    final tariff = resource['tariffs'];
    final familyLabel = resource['resource_types'] is Map
        ? (resource['resource_types']['family'] == 'BILLIARD'
            ? 'Bilyard'
            : resource['resource_types']['family'] == 'PLAYSTATION'
                ? 'PlayStation'
                : '')
        : '';
    return Card(
      clipBehavior: Clip.antiAlias,
      color: active
          ? (paused
              ? Color.alphaBlend(
                  VColors.orange.withValues(alpha: .08), VColors.surface)
              : Color.alphaBlend(
                  VColors.green.withValues(alpha: .08), VColors.surface))
          : VColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        side: BorderSide(
          color:
              active ? (paused ? VColors.orange : VColors.green) : VColors.line,
          width: active ? 1.5 : 1,
        ),
      ),
      child: InkWell(
        onTap: () {
          if (active) {
            _sessionDialog(context);
          } else if (syncing) {
            showDone(context, tr('Stol band. Ma\'lumot yangilanmoqda'));
            controller.refresh();
          } else {
            _startDialog(context);
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.radio_button_checked_rounded,
                      size: 18, color: active ? VColors.green : VColors.muted),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text('${resource['name']}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 19, fontWeight: FontWeight.w900)),
                  ),
                  Icon(Icons.power_settings_new,
                      size: 19, color: active ? VColors.green : VColors.subtle),
                ],
              ),
              const SizedBox(height: 10),
              if (syncing) ...[
                _StatusPill(
                  label: tr('YANGILANMOQDA'),
                  background: VColors.orange.withValues(alpha: .16),
                  foreground: VColors.orange,
                ),
                const Spacer(),
                Text(tr('Stol band'),
                    style: TextStyle(
                        color: VColors.orange,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
                Text(tr('Faol seans yuklanmoqda'),
                    style: TextStyle(color: VColors.subtle)),
              ] else if (!active) ...[
                _StatusPill(
                  label: tr('BO\'SH'),
                  background: VColors.field,
                  foreground: VColors.muted,
                ),
                const Spacer(),
                if (reservation != null) ...[
                  Text('${tr('Bron')} ${_clockOf(reservation!['starts_at'])}',
                      style: TextStyle(
                          color: VColors.orange,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                  if ((reservation!['players_count'] as num?) != null)
                    Text('${reservation!['players_count']}',
                        style: TextStyle(color: VColors.subtle, fontSize: 13)),
                  const SizedBox(height: 6),
                ],
                Text(
                    '${money(tariff is Map ? tariff['price_per_hour'] : 0)}/${tr('soat')}',
                    style: TextStyle(
                        color: VColors.muted,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
                Text('${tariff is Map ? tariff['name'] ?? '' : ''}',
                    style: TextStyle(color: VColors.subtle)),
              ] else
                Expanded(
                  child: _ActiveBody(
                    session: session!,
                    tariff: tariff is Map
                        ? Map<String, dynamic>.from(tariff)
                        : null,
                    familyLabel: familyLabel,
                    onPause: () => _pause(context),
                    onResume: () => _resume(context),
                    onRound: () => _round(context),
                    onTimeUp: () => _timeUp(context),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pause(BuildContext context) async {
    try {
      await controller.repository.pauseSession('${session!['id']}');
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _timeUp(BuildContext context) async {
    // Enforce the paid time physically, not just on screen — cut the relay
    // the instant time is up, before the cashier has even decided anything.
    if (resource['relay_device_id'] != null) {
      try {
        final device = await controller.repository
            .relayDeviceForResource('${resource['id']}');
        await controller.repository.switchRelayDevice(device, false);
        await controller.repository.relayCommand('${resource['id']}', false);
      } catch (_) {
        // Best-effort — a relay hiccup shouldn't block the decision dialog.
      }
    }
    if (!context.mounted) return;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(tr('Vaqt tugadi')),
        content: Text(LocaleController.instance.isRu
            ? 'Время, назначенное для «${resource['name']}», истекло. Продолжить или завершить?'
            : '${resource['name']} uchun belgilangan vaqt tugadi. Davom ettirasizmi yoki yakunlaysizmi?'),
        actions: [
          OutlinedButton(
              onPressed: () => Navigator.pop(c, 'continue'),
              child: Text(tr('Davom ettirish'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, 'finish'),
              child: Text(tr('Yakunlash'))),
        ],
      ),
    );
    if (!context.mounted) return;

    if (action == 'finish') {
      try {
        await controller.repository.finishSession('${session!['id']}');
        final orderId = session!['order_id'];
        controller.refresh();
        if (context.mounted && orderId != null) {
          await showSessionPaymentDialog(
            context,
            controller: controller,
            orderId: '$orderId',
            sessionId: '${session!['id']}',
            resourceName: '${resource['name']}',
            pricePerHour: _pricePerHour,
            familyLabel: _familyLabel,
          );
          controller.refresh();
        }
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
      return;
    }

    if (action == 'continue') {
      final tariff = resource['tariffs'];
      final pricePerHour =
          (tariff is Map ? tariff['price_per_hour'] as num? : null)
                  ?.toDouble() ??
              0;
      final amountCtrl = TextEditingController();
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          scrollable: true,
          title: Text(tr('Qo\'shimcha vaqt')),
          content: TextField(
            controller: amountCtrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
                labelText: tr('Qo\'shimcha summa'), suffixText: tr('so\'m')),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: Text(tr('Bekor qilish'))),
            FilledButton(
                onPressed: () => Navigator.pop(c, true),
                child: Text(tr('Davom ettirish'))),
          ],
        ),
      );
      if (ok != true) return;
      final amount = int.tryParse(amountCtrl.text) ?? 0;
      if (amount <= 0 || pricePerHour <= 0) return;
      final minutes = (amount / pricePerHour * 60).round();
      try {
        await controller.repository
            .extendSessionTimer('${session!['id']}', minutes);
        if (resource['relay_device_id'] != null) {
          final device = await controller.repository
              .relayDeviceForResource('${resource['id']}');
          await controller.repository.switchRelayDevice(device, true);
          await controller.repository.relayCommand('${resource['id']}', true);
        }
        controller.refresh();
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }
  }

  Future<void> _resume(BuildContext context) async {
    try {
      await controller.repository.resumeSession('${session!['id']}');
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _round(BuildContext context) async {
    final noteCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        scrollable: true,
        title: Text(tr('Yangi raund')),
        content: TextField(
          controller: noteCtrl,
          autofocus: true,
          decoration: InputDecoration(
              labelText: tr('Izoh (ixtiyoriy)'),
              hintText: tr('Masalan, kim to\'laydi — chekda ko\'rinadi')),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('Bekor qilish'))),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('Raund'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await controller.repository.sessionNewRound('${session!['id']}',
          note: noteCtrl.text.trim().isEmpty ? null : noteCtrl.text.trim());
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _startDialog(BuildContext context) async {
    String? tariffId = resource['default_tariff_id']?.toString();
    String? customerId;
    String? customerLabel;
    int? plannedMinutes;
    final prepaidAmountCtrl = TextEditingController();

    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: Text(
              '${LocaleController.instance.isRu ? 'Запуск' : 'Ishga tushirish'} — ${resource['name']}'),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('Mijoz'),
                    style: TextStyle(color: VColors.muted, fontSize: 13)),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final id = await pickCustomer(context, customers);
                      if (id == null) return;
                      final c = customers.firstWhere((c) => '${c['id']}' == id);
                      setState(() {
                        customerId = id;
                        customerLabel =
                            '${c['full_name'] ?? c['phone'] ?? 'Mijoz'}';
                      });
                    },
                    icon: const Icon(Icons.person_outline_rounded),
                    label: Text(customerLabel ?? tr('Mijozsiz')),
                  ),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: tariffId,
                  decoration: InputDecoration(labelText: tr('Tarif')),
                  items: tariffs
                      .map((t) => DropdownMenuItem(
                            value: '${t['id']}',
                            child: Text(
                                '${t['name']} · ${money(t['price_per_hour'])}/${tr('soat')}'),
                          ))
                      .toList(),
                  onChanged: (v) => setState(() {
                    tariffId = v;
                    final amount = int.tryParse(prepaidAmountCtrl.text);
                    final tariff = tariffs.firstWhere(
                        (t) => '${t['id']}' == tariffId,
                        orElse: () => const {});
                    final pricePerHour =
                        (tariff['price_per_hour'] as num?)?.toDouble();
                    plannedMinutes = (amount == null ||
                            amount <= 0 ||
                            pricePerHour == null ||
                            pricePerHour <= 0)
                        ? null
                        : (amount / pricePerHour * 60).round();
                  }),
                ),
                const SizedBox(height: 16),
                Text(tr('To\'lov summasi bo\'yicha vaqt (ixtiyoriy)'),
                    style: TextStyle(color: VColors.muted, fontSize: 13)),
                const SizedBox(height: 6),
                TextField(
                  controller: prepaidAmountCtrl,
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                      hintText: tr('Summa — bo\'sh qoldirsangiz cheklanmagan'),
                      suffixText: tr('so\'m')),
                  onChanged: (v) {
                    final amount = int.tryParse(v);
                    final tariff = tariffs.firstWhere(
                        (t) => '${t['id']}' == tariffId,
                        orElse: () => const {});
                    final pricePerHour =
                        (tariff['price_per_hour'] as num?)?.toDouble();
                    setState(() {
                      plannedMinutes = (amount == null ||
                              amount <= 0 ||
                              pricePerHour == null ||
                              pricePerHour <= 0)
                          ? null
                          : (amount / pricePerHour * 60).round();
                    });
                  },
                ),
                if (plannedMinutes != null) ...[
                  const SizedBox(height: 4),
                  Text(
                      LocaleController.instance.isRu
                          ? '≈ $plannedMinutes ${tr('daqiqa')} — по истечении стол завершится автоматически'
                          : '≈ $plannedMinutes daqiqa — shu vaqtdan so\'ng stol avtomatik yakunlanadi',
                      style: TextStyle(color: VColors.subtle, fontSize: 11.5)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(tr('Bekor qilish'))),
            FilledButton(
                onPressed: tariffId == null
                    ? null
                    : () => Navigator.pop(context, true),
                child: Text(tr('Boshlash'))),
          ],
        ),
      ),
    );
    if (ok != true || tariffId == null || !context.mounted) return;
    try {
      await controller.repository.startSession(
        clubId: controller.context!.clubId,
        resourceId: '${resource['id']}',
        tariffId: tariffId!,
        customerId: customerId,
        plannedMinutes: plannedMinutes,
      );
      if (context.mounted) showDone(context, tr('Seans boshlandi'));
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _sessionDialog(BuildContext context) async {
    final sessionId = '${session!['id']}';
    final orderId = session!['order_id'];
    final isPaused = session!['status'] == 'PAUSED';
    final familyLabel = resource['resource_types'] is Map
        ? '${resource['resource_types']['family']}'
        : '';

    // The card on the hall grid (_ActiveBody._amount) computes the live time
    // charge from banked_time_amount + price_per_hour * elapsed seconds --
    // mirrored here so this dialog's number always matches what the cashier
    // just saw on the card, rather than depending on session_current_charge's
    // response shape (its jsonb key is time_amount, not amount -- reading
    // charge['amount'] silently returned null and fell back to the session
    // row's own stale time_amount column, which stays 0 until the session is
    // paused/rounded/finished for the first time).
    final tariff = resource['tariffs'];
    final pricePerHour =
        (tariff is Map ? tariff['price_per_hour'] as num? : null) ?? 0;
    final startedAt = DateTime.tryParse('${session!['started_at']}');
    var elapsedSeconds = startedAt == null
        ? 0
        : DateTime.now().toUtc().difference(startedAt.toUtc()).inSeconds -
            ((session!['paused_seconds'] as num?)?.toInt() ?? 0);
    if (isPaused) {
      final pausedAt = DateTime.tryParse('${session!['pause_started_at']}');
      if (pausedAt != null) {
        elapsedSeconds -=
            DateTime.now().toUtc().difference(pausedAt.toUtc()).inSeconds;
      }
    }
    if (elapsedSeconds < 0) elapsedSeconds = 0;
    final bankedAmount = (session!['banked_time_amount'] as num?)?.toInt() ?? 0;
    final timeAmount =
        bankedAmount + (pricePerHour * elapsedSeconds / 3600).round();
    final durationLabel = elapsedSeconds >= 3600
        ? '${elapsedSeconds ~/ 3600} soat ${(elapsedSeconds % 3600) ~/ 60} daq'
        : '${elapsedSeconds ~/ 60} daq';

    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Dialog(
        child: SizedBox(
          width: 460,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: FutureBuilder<List<dynamic>>(
              future: Future.wait([
                controller.repository.sessionRounds(sessionId),
                orderId == null
                    ? Future.value(null)
                    : controller.repository.client
                        .from('orders')
                        .select('items_amount,discount_amount')
                        .eq('id', '$orderId')
                        .maybeSingle(),
              ]),
              builder: (context, snap) {
                final rounds =
                    (snap.data?[0] as List<Map<String, dynamic>>?) ?? [];
                final order = snap.data?[1] as Map<String, dynamic>?;
                final itemsAmount =
                    (order?['items_amount'] as num?)?.toInt() ?? 0;
                final discountAmount =
                    (order?['discount_amount'] as num?)?.toInt() ?? 0;
                final totalAmount = timeAmount + itemsAmount - discountAmount;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Expanded(
                        child: Text('${resource['name']}',
                            style: const TextStyle(
                                fontWeight: FontWeight.w900, fontSize: 20)),
                      ),
                      IconButton(
                          onPressed: () => Navigator.pop(dialogContext),
                          icon: const Icon(Icons.close_rounded)),
                    ]),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(18),
                      decoration: BoxDecoration(
                        border: Border.all(color: VColors.green, width: 1.5),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(durationLabel,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w900,
                                            fontSize: 28)),
                                    const SizedBox(height: 4),
                                    Text(
                                        tr(familyLabel == 'BILLIARD'
                                            ? 'Bilyard'
                                            : familyLabel == 'PLAYSTATION'
                                                ? 'PlayStation'
                                                : ''),
                                        style: TextStyle(color: VColors.muted)),
                                  ],
                                ),
                              ),
                              Text(money(totalAmount),
                                  style: TextStyle(
                                      color: VColors.green,
                                      fontWeight: FontWeight.w900,
                                      fontSize: 24)),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Row(children: [
                            Expanded(
                              child: _AmountStat(
                                  label: tr('Vaqt uchun'), value: timeAmount),
                            ),
                            Expanded(
                              child: _AmountStat(
                                  label: tr('Bar uchun'), value: itemsAmount),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    if (rounds.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      ...rounds.reversed.map((r) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Text('${tr('Raund')} ${r['round_number']}:',
                                      style: TextStyle(color: VColors.muted)),
                                  const SizedBox(width: 6),
                                  Text(money(r['amount']),
                                      style: TextStyle(color: VColors.muted)),
                                ]),
                                if ('${r['note'] ?? ''}'.trim().isNotEmpty)
                                  Padding(
                                    padding:
                                        const EdgeInsets.only(left: 4, top: 1),
                                    child: Text('${r['note']}',
                                        style: TextStyle(
                                            color: VColors.subtle,
                                            fontSize: 12)),
                                  ),
                              ],
                            ),
                          )),
                    ],
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pop(dialogContext, 'products'),
                        icon: const Icon(Icons.shopping_cart_outlined),
                        label: Text(tr('Tovar qo\'shish')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: () =>
                            Navigator.pop(dialogContext, 'transfer'),
                        icon: const Icon(Icons.swap_horiz_rounded),
                        label: Text(tr('Boshqa joyga ko\'chirish')),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.pop(
                              dialogContext, isPaused ? 'resume' : 'pause'),
                          icon: Icon(isPaused
                              ? Icons.play_arrow_rounded
                              : Icons.pause_rounded),
                          label:
                              Text(tr(isPaused ? 'Davom ettirish' : 'Pauza')),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () =>
                              Navigator.pop(dialogContext, 'cancel'),
                          style: OutlinedButton.styleFrom(
                              foregroundColor: VColors.red),
                          child: Text(tr('Bekor qilish')),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: () => Navigator.pop(dialogContext, 'finish'),
                        icon: const Icon(Icons.point_of_sale_rounded),
                        label: Text(tr('Yakunlash va to\'lash')),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
    if (action == null || !context.mounted) return;

    switch (action) {
      case 'products':
        final orderId = session!['order_id'];
        if (orderId == null) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SessionProductsPage(
              controller: controller,
              orderId: '$orderId',
              resourceName: '${resource['name']}',
            ),
          ),
        );
        controller.refresh();
        return;
      case 'transfer':
        await _transferDialog(context);
        return;
      case 'pause':
        try {
          await controller.repository.pauseSession(sessionId);
          controller.refresh();
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
        return;
      case 'resume':
        try {
          await controller.repository.resumeSession(sessionId);
          controller.refresh();
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
        return;
      case 'cancel':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (c) => AlertDialog(
            scrollable: true,
            title: Text(tr('Seansni bekor qilish')),
            content: Text(tr(
                'Seans bekor qilinadi, hisob yopiladi. Bu amalni qaytarib bo\'lmaydi.')),
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
          await controller.repository.cancelSession(sessionId);
          controller.refresh();
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
        return;
      case 'finish':
        try {
          await controller.repository.finishSession(sessionId);
          final orderId = session!['order_id'];
          controller.refresh();
          if (context.mounted && orderId != null) {
            await showSessionPaymentDialog(
              context,
              controller: controller,
              orderId: '$orderId',
              sessionId: sessionId,
              resourceName: '${resource['name']}',
              pricePerHour: _pricePerHour,
              familyLabel: _familyLabel,
            );
            controller.refresh();
          }
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
        return;
    }
  }

  Future<void> _transferDialog(BuildContext context) async {
    final myTypeId = resource['resource_type_id'];
    final candidates = allResources
        .where((r) => r['id'] != resource['id'])
        .where((r) => r['resource_type_id'] == myTypeId)
        .where((r) => sessionByResource['${r['id']}'] == null)
        .toList();
    if (candidates.isEmpty) {
      showError(context, Exception(tr('Bo\'sh joy topilmadi')));
      return;
    }
    final targetId = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Qaysi joyga ko\'chiramiz?')),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: candidates
                .map((r) => ListTile(
                      leading: Icon(Icons.radio_button_checked_rounded,
                          color: VColors.green),
                      title: Text('${r['name']}'),
                      onTap: () => Navigator.pop(context, '${r['id']}'),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(tr('Bekor qilish'))),
        ],
      ),
    );
    if (targetId == null) return;
    try {
      await controller.repository
          .transferSession('${session!['id']}', targetId);
      if (context.mounted) showDone(context, tr('Ko\'chirildi'));
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}
