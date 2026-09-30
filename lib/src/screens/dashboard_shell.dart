import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../i18n.dart';
import '../services/notification_sound.dart';
import '../utils.dart';
import '../state/club_controller.dart';
import '../theme.dart';
import 'club_page.dart';
import 'customers_page.dart';
import 'expenses_page.dart';
import 'orders_page.dart';
import 'products_page.dart';
import 'relay_page.dart';
import 'reports_page.dart';
import 'reservations_page.dart';
import 'sales_page.dart';
import 'settings_page.dart';
import 'shift_page.dart';
import 'staff_page.dart';
import 'waitlist_page.dart';

class _NavItem {
  const _NavItem(this.label, this.icon, this.page,
      {this.cashierVisible = true});
  final String label;
  final IconData icon;
  final Widget page;
  final bool cashierVisible;
}

class DashboardShell extends StatelessWidget {
  const DashboardShell({super.key, required this.controller});

  final ClubController controller;

  @override
  Widget build(BuildContext context) {
    final allItems = [
      _NavItem(
          'Klub', Icons.grid_view_rounded, ClubPage(controller: controller)),
      _NavItem('Sotuvlar', Icons.storefront_outlined,
          SalesPage(controller: controller)),
      _NavItem('Bronlar', Icons.event_available_outlined,
          ReservationsPage(controller: controller)),
      _NavItem('Navbat', Icons.hourglass_empty_rounded,
          WaitlistPage(controller: controller)),
      _NavItem('Mijozlar', Icons.groups_outlined,
          CustomersPage(controller: controller)),
      _NavItem('Cheklar', Icons.receipt_long_outlined,
          OrdersPage(controller: controller)),
      _NavItem('Smena', Icons.point_of_sale_outlined,
          ShiftPage(controller: controller)),
      _NavItem('Tovarlar', Icons.inventory_2_outlined,
          ProductsPage(controller: controller),
          cashierVisible: false),
      _NavItem('Xarajatlar', Icons.request_quote_outlined,
          ExpensesPage(controller: controller)),
      _NavItem('Hisobotlar', Icons.bar_chart_rounded,
          ReportsPage(controller: controller),
          cashierVisible: false),
      _NavItem('Rele', Icons.settings_remote_outlined,
          RelayPage(controller: controller),
          cashierVisible: false),
      _NavItem(
          'Xodimlar', Icons.badge_outlined, StaffPage(controller: controller),
          cashierVisible: false),
      _NavItem('Sozlamalar', Icons.settings_outlined,
          SettingsPage(controller: controller),
          cashierVisible: false),
    ];
    final isCashier = controller.context?.isCashier ?? false;
    final items =
        isCashier ? allItems.where((i) => i.cashierVisible).toList() : allItems;
    final pages = items.map((i) => i.page).toList();
    final activePage = controller.page.clamp(0, pages.length - 1);
    return LayoutBuilder(builder: (context, constraints) {
      // Phones and tablets in portrait: the sidebar becomes a drawer behind
      // a menu button, and the top bar drops what doesn't fit.
      final compact = constraints.maxWidth < _compactWidth;
      // Tablets: the full-width sidebar would eat a third of the screen --
      // it stays icon-only there whatever the saved preference is.
      final expanded =
          controller.sidebarExpanded && constraints.maxWidth >= 1100;
      final width = expanded ? 232.0 : 68.0;
      final content = Column(
        children: [
          _TopBar(controller: controller, compact: compact),
          Expanded(
            child: IndexedStack(index: activePage, children: pages),
          ),
        ],
      );
      if (compact) {
        return Scaffold(
          drawer: Drawer(
            backgroundColor: VColors.surface,
            child: SafeArea(
              child: Builder(
                builder: (drawerContext) => _sidebar(items, activePage,
                    expanded: true,
                    onPicked: () => Navigator.of(drawerContext).pop()),
              ),
            ),
          ),
          body: SafeArea(child: content),
        );
      }
      return Scaffold(
        body: SafeArea(
          child: Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                width: width,
                color: VColors.surface,
                child: _sidebar(items, activePage,
                    expanded: expanded,
                    canToggle: constraints.maxWidth >= 1100),
              ),
              Expanded(child: content),
            ],
          ),
        ),
      );
    });
  }

  Widget _sidebar(List<_NavItem> items, int activePage,
      {required bool expanded, bool canToggle = true, VoidCallback? onPicked}) {
    return Column(
      children: [
        SizedBox(
          height: 72,
          child: expanded
              ? Row(
                  children: [
                    const SizedBox(width: 18),
                    Icon(Icons.sports_esports_rounded,
                        color: VColors.green, size: 22),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        controller.context!.clubName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 16),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Menyuni yig\'ish',
                      onPressed: controller.toggleSidebar,
                      icon: const Icon(Icons.keyboard_double_arrow_left_rounded,
                          size: 19),
                      color: VColors.muted,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    const SizedBox(width: 12),
                  ],
                )
              : Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.sports_esports_rounded,
                        color: VColors.green, size: 22),
                    if (canToggle) ...[
                      const SizedBox(height: 4),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: 'Menyuni ochish',
                        onPressed: controller.toggleSidebar,
                        icon: const Icon(Icons.menu_rounded, size: 19),
                        color: VColors.muted,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
                    ],
                  ],
                ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            itemCount: items.length,
            itemBuilder: (context, index) {
              final item = items[index];
              final active = activePage == index;
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Material(
                  color: active ? VColors.greenSoft : Colors.transparent,
                  borderRadius: BorderRadius.circular(12),
                  child: InkWell(
                    onTap: () {
                      controller.go(index);
                      onPicked?.call();
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: SizedBox(
                      height: 42,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            child: Icon(item.icon,
                                size: 19,
                                color: active ? VColors.green : VColors.muted),
                          ),
                          if (expanded)
                            Expanded(
                              child: Text(tr(item.label),
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: active ? VColors.ink : VColors.muted,
                                    fontWeight: active
                                        ? FontWeight.w800
                                        : FontWeight.w600,
                                    fontSize: 14,
                                  )),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

const _compactWidth = 760.0;

class _TopBar extends StatelessWidget {
  const _TopBar({required this.controller, this.compact = false});
  final ClubController controller;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final showUser = !compact && MediaQuery.sizeOf(context).width >= 1100;
    return Container(
      height: compact ? 60 : 72,
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 24),
      decoration: BoxDecoration(
        color: VColors.surface,
        border: Border(bottom: BorderSide(color: VColors.line)),
      ),
      child: Row(
        children: [
          if (compact)
            IconButton(
              tooltip: tr('Menyu'),
              onPressed: () => Scaffold.of(context).openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            )
          else
            const PillStatus(),
          const Spacer(),
          _NotificationsBell(controller: controller),
          const SizedBox(width: 8),
          InkWell(
            borderRadius: BorderRadius.circular(11),
            onTap: LocaleController.instance.toggle,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: VColors.field,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: VColors.line),
              ),
              child: Text(LocaleController.instance.locale.toUpperCase(),
                  style: const TextStyle(
                      fontWeight: FontWeight.w800, fontSize: 13)),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: tr('Mavzu'),
            onPressed: ThemeController.instance.toggle,
            iconSize: 21,
            icon: Icon(ThemeController.instance.isDark
                ? Icons.dark_mode_rounded
                : Icons.light_mode_outlined),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: tr('Printer sozlamalari'),
            onPressed: () => showPrinterSettingsDialog(context, controller),
            iconSize: 21,
            icon: const Icon(Icons.print_outlined),
          ),
          if (showUser) ...[
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(controller.context!.userName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 14)),
                  Text(controller.context!.roleName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: VColors.muted, fontSize: 11)),
                ],
              ),
            ),
          ],
          const SizedBox(width: 8),
          IconButton(
            tooltip: tr('Chiqish'),
            onPressed: () => Supabase.instance.client.auth.signOut(),
            iconSize: 21,
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
      ),
    );
  }
}

class PillStatus extends StatelessWidget {
  const PillStatus({super.key});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: VColors.greenSoft,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.wifi_rounded, color: VColors.green, size: 16),
            const SizedBox(width: 6),
            Text(tr('Onlayn'),
                style: TextStyle(
                    color: VColors.green,
                    fontWeight: FontWeight.w700,
                    fontSize: 13)),
          ],
        ),
      );
}

/// Polls low-stock products and pending reservations in the background and
/// plays a system alert the moment the combined count grows — so a cashier
/// notices a new booking or an empty shelf without having to open the page.
/// "Read" state is per-session only (no backend table for it yet).
class _NotificationsBell extends StatefulWidget {
  const _NotificationsBell({required this.controller});
  final ClubController controller;

  @override
  State<_NotificationsBell> createState() => _NotificationsBellState();
}

class _NotificationsBellState extends State<_NotificationsBell> {
  Timer? _timer;
  List<Map<String, dynamic>> _lowStock = [];
  List<Map<String, dynamic>> _pending = [];
  final Set<String> _dismissed = {};
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load(initial: true);
    // The realtime subscription (club_repository.subscribeClub) now covers
    // `reservations` too, so a new booking from the bot/Mini App notifies
    // immediately -- this timer is just the fallback in case a realtime
    // event gets missed (a dropped connection, a brief reconnect window).
    widget.controller.addListener(_onControllerChanged);
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => _load());
  }

  void _onControllerChanged() => _load();

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool initial = false}) async {
    final clubId = widget.controller.context?.clubId;
    if (clubId == null) return;
    try {
      final repo = widget.controller.repository;
      final results = await Future.wait([
        repo.products(clubId),
        repo.reservations(clubId),
      ]);
      final products = (results[0] as List).cast<Map<String, dynamic>>();
      final reservations = (results[1] as List).cast<Map<String, dynamic>>();
      final lowStock = products
          .where((p) =>
              p['active'] == true &&
              p['track_stock'] != false &&
              ((p['stock_quantity'] as num?) ?? 0) <=
                  ((p['minimum_stock'] as num?) ?? 0))
          .toList();
      final pending =
          reservations.where((r) => r['status'] == 'pending').toList();
      if (!mounted) return;
      final newTotal = lowStock.length + pending.length;
      final oldTotal = _lowStock.length + _pending.length;
      if (!initial && newTotal > oldTotal) {
        unawaited(playNotificationSound());
      }
      setState(() {
        _lowStock = lowStock;
        _pending = pending;
        _loaded = true;
      });
    } catch (_) {
      // A failed background poll shouldn't disrupt the shell.
    }
  }

  int get _count =>
      _lowStock.where((p) => !_dismissed.contains('p:${p['id']}')).length +
      _pending.where((r) => !_dismissed.contains('r:${r['id']}')).length;

  @override
  Widget build(BuildContext context) {
    final count = _count;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: 'Bildirishnomalar',
          onPressed: _loaded ? () => _openMenu(context) : null,
          iconSize: 21,
          icon: const Icon(Icons.notifications_none_rounded),
        ),
        if (count > 0)
          Positioned(
            right: 6,
            top: 6,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: VColors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                constraints: const BoxConstraints(minWidth: 16),
                child: Text('$count',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w800)),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _openMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final offset = box.localToGlobal(Offset(0, box.size.height));
    await showMenu<void>(
      context: context,
      position: RelativeRect.fromLTRB(
          offset.dx - 320, offset.dy + 6, offset.dx, offset.dy),
      color: VColors.surface,
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: VColors.line)),
      items: [
        PopupMenuItem<void>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 340,
            child: StatefulBuilder(builder: (menuContext, setMenuState) {
              final lowStock = _lowStock
                  .where((p) => !_dismissed.contains('p:${p['id']}'))
                  .toList();
              final pending = _pending
                  .where((r) => !_dismissed.contains('r:${r['id']}'))
                  .toList();
              return Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Bildirishnomalar',
                        style: TextStyle(
                            fontWeight: FontWeight.w900, fontSize: 15)),
                    const SizedBox(height: 10),
                    if (lowStock.isEmpty && pending.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text('Bildirishnomalar yo\'q',
                              style: TextStyle(color: VColors.muted)),
                        ),
                      ),
                    if (pending.isNotEmpty) ...[
                      Text('Bronlar',
                          style: TextStyle(
                              color: VColors.muted,
                              fontWeight: FontWeight.w700,
                              fontSize: 12)),
                      const SizedBox(height: 6),
                      ...pending.take(8).map((r) {
                        final resource = r['resources'];
                        final resourceName =
                            resource is Map ? '${resource['name']}' : '';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(children: [
                            Icon(Icons.event_available_outlined,
                                size: 16, color: VColors.blue),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                  '${r['customer_name'] ?? ''} · $resourceName · ${shortDate(r['starts_at'])}',
                                  style: const TextStyle(fontSize: 13)),
                            ),
                          ]),
                        );
                      }),
                      const SizedBox(height: 8),
                    ],
                    if (lowStock.isNotEmpty) ...[
                      Text('Tovar tugayapti',
                          style: TextStyle(
                              color: VColors.muted,
                              fontWeight: FontWeight.w700,
                              fontSize: 12)),
                      const SizedBox(height: 6),
                      ...lowStock.take(8).map((p) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 5),
                            child: Row(children: [
                              Icon(Icons.warning_amber_rounded,
                                  size: 16, color: VColors.orange),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text('${p['name']}',
                                    style: const TextStyle(fontSize: 13)),
                              ),
                              Text(
                                  '${(p['stock_quantity'] as num?) ?? 0} ${p['unit'] ?? ''}',
                                  style: TextStyle(
                                      color: VColors.orange,
                                      fontWeight: FontWeight.w700,
                                      fontSize: 12)),
                            ]),
                          )),
                    ],
                    if (lowStock.isNotEmpty || pending.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: () {
                            setState(() {
                              for (final p in lowStock) {
                                _dismissed.add('p:${p['id']}');
                              }
                              for (final r in pending) {
                                _dismissed.add('r:${r['id']}');
                              }
                            });
                            Navigator.pop(menuContext);
                          },
                          child:
                              const Text('Barchasini o\'qilgan deb belgilash'),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ),
        ),
      ],
    );
  }
}
