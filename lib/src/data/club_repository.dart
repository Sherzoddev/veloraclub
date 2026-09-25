import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/printer_service.dart';
import '../utils.dart';

class ClubContextData {
  const ClubContextData({
    required this.club,
    required this.member,
    required this.role,
    required this.profile,
  });

  final Map<String, dynamic> club;
  final Map<String, dynamic> member;
  final Map<String, dynamic> role;
  final Map<String, dynamic> profile;

  String get clubId => '${club['id']}';
  String get clubName => '${club['name'] ?? 'Velora Club'}';
  String get userName => '${profile['full_name'] ?? 'Foydalanuvchi'}';
  String get roleName => '${role['name'] ?? role['key'] ?? ''}';
  String get roleKey => '${role['key'] ?? ''}';
  bool get isOwner => role['is_owner'] == true;
  bool get isCashier => roleKey == 'cashier';
}

class ClubRepository {
  ClubRepository([SupabaseClient? client])
      : client = client ?? Supabase.instance.client;

  final SupabaseClient client;

  User? get user => client.auth.currentUser;

  Future<ClubContextData> loadContext() async {
    final current = user;
    if (current == null) throw Exception('Avval tizimga kiring');
    final memberRows = rowList(await client
        .from('club_members')
        .select('*, clubs(*), roles(*)')
        .eq('user_id', current.id)
        .eq('active', true)
        .limit(1));
    if (memberRows.isEmpty) {
      throw Exception('Bu foydalanuvchiga klub biriktirilmagan');
    }
    final member = memberRows.first;
    final profileRows = rowList(
        await client.from('profiles').select().eq('id', current.id).limit(1));
    return ClubContextData(
      club: rowMap(member['clubs']),
      member: member,
      role: rowMap(member['roles']),
      profile: profileRows.isEmpty
          ? {'id': current.id, 'full_name': current.email}
          : profileRows.first,
    );
  }

  Future<List<Map<String, dynamic>>> resources(String clubId) async => rowList(
        await client
            .from('resources')
            .select('*, resource_types(*), tariffs(*)')
            .eq('club_id', clubId)
            .eq('active', true)
            .order('sort_order', ascending: true)
            .order('number', ascending: true),
      );

  Future<List<Map<String, dynamic>>> activeSessions(String clubId) async =>
      rowList(await client
          .from('game_sessions')
          .select(
              '*, customers(id,full_name,phone), orders!orders_session_id_fkey(*)')
          .eq('club_id', clubId)
          .inFilter('status', [
        'STARTING',
        'ACTIVE',
        'PAUSED',
        'STOPPING'
      ]).order('started_at', ascending: true));

  Future<List<Map<String, dynamic>>> tariffs(String clubId) async => rowList(
        await client
            .from('tariffs')
            .select()
            .eq('club_id', clubId)
            .eq('active', true)
            .order('sort_order', ascending: true),
      );

  Future<List<Map<String, dynamic>>> products(String clubId) async => rowList(
        await client
            .from('products')
            .select('*, product_categories(*)')
            .eq('club_id', clubId)
            .isFilter('archived_at', null)
            .order('sort_order', ascending: true),
      );

  /// Quantity sold per product over the trailing [days] — used to sort the
  /// sales grids so bestsellers surface first automatically.
  Future<Map<String, num>> productSalesStats(String clubId,
      {int days = 30}) async {
    final rows = rowList(await client.rpc('product_sales_stats',
        params: {'p_club_id': clubId, 'p_days': days}));
    return {
      for (final r in rows) '${r['product_id']}': (r['qty'] as num?) ?? 0,
    };
  }

  Future<List<Map<String, dynamic>>> productCategories(String clubId) async =>
      rowList(await client
          .from('product_categories')
          .select()
          .eq('club_id', clubId)
          .eq('active', true)
          .order('sort_order', ascending: true));

  Future<List<Map<String, dynamic>>> customers(String clubId) async => rowList(
        await client
            .from('customers')
            .select('*, loyalty_tiers!customers_tier_id_fkey(*)')
            .eq('club_id', clubId)
            .isFilter('archived_at', null)
            .order('created_at', ascending: false),
      );

  Future<List<Map<String, dynamic>>> reservations(String clubId) async =>
      rowList(
        await client
            .from('reservations')
            .select('*, resources(name), customers(full_name,phone)')
            .eq('club_id', clubId)
            .order('starts_at', ascending: true),
      );

  Future<List<Map<String, dynamic>>> waitlist(String clubId) async => rowList(
        await client.rpc('waitlist_list', params: {'p_club_id': clubId}),
      );

  Future<List<Map<String, dynamic>>> orders(String clubId) async => rowList(
        await client
            .from('orders')
            .select(
                '*, customers(full_name,phone), game_sessions!orders_session_id_fkey(resources(name)), opener:profiles!orders_opened_by_fkey(full_name)')
            .eq('club_id', clubId)
            .order('created_at', ascending: false)
            .limit(150),
      );

  Future<List<Map<String, dynamic>>> shifts(String clubId) async => rowList(
        await client
            .from('cash_shifts')
            .select('*, profiles!cash_shifts_opened_by_fkey(full_name)')
            .eq('club_id', clubId)
            .order('opened_at', ascending: false)
            .limit(30),
      );

  /// Server-side, timezone-correct period totals (revenue split into
  /// PlayStation/Bilyard time vs bar/products, expenses, net profit) —
  /// the same aggregation the club-bot's own /reports uses, so the desktop
  /// app and the bot never disagree on "today's" numbers.
  Future<Map<String, dynamic>> periodReport(
          String clubId, DateTime from, DateTime to) async =>
      rowMap(await client.rpc('app_period_report', params: {
        'p_club_id': clubId,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
      }));

  /// Chart data for the reports dashboard: a gap-filled revenue/orders series
  /// bucketed by [bucket] ('hour' | 'day' | 'month') in the club's timezone,
  /// revenue split by table family / bar category, and top products.
  Future<Map<String, dynamic>> reportDashboard(
          String clubId, DateTime from, DateTime to, String bucket) async =>
      rowMap(await client.rpc('app_report_dashboard', params: {
        'p_club_id': clubId,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
        'p_bucket': bucket,
      }));

  Future<Map<String, dynamic>> shiftTotals(String shiftId) async =>
      rowMap(await client.rpc('shift_totals', params: {'p_shift_id': shiftId}));

  Future<List<Map<String, dynamic>>> expenses(String clubId) async => rowList(
        await client
            .from('expenses')
            .select(
                '*, expense_categories(name), profiles!expenses_created_by_fkey(full_name)')
            .eq('club_id', clubId)
            .order('spent_at', ascending: false)
            .limit(150),
      );

  Future<List<Map<String, dynamic>>> expenseCategories(String clubId) async =>
      rowList(await client
          .from('expense_categories')
          .select()
          .eq('club_id', clubId)
          .eq('active', true)
          .order('sort_order', ascending: true));

  Future<List<Map<String, dynamic>>> zones(String clubId) async => rowList(
        await client
            .from('zones')
            .select()
            .eq('club_id', clubId)
            .eq('active', true)
            .order('sort_order', ascending: true),
      );

  Future<List<Map<String, dynamic>>> resourceTypes(String clubId) async =>
      rowList(await client
          .from('resource_types')
          .select()
          .or('club_id.is.null,club_id.eq.$clubId')
          .order('sort_order', ascending: true));

  Future<List<Map<String, dynamic>>> discounts(String clubId) async => rowList(
        await client
            .from('discounts')
            .select()
            .eq('club_id', clubId)
            .order('created_at', ascending: true),
      );

  Future<List<Map<String, dynamic>>> relayDevices(String clubId) async =>
      rowList(
        await client
            .rpc('app_admin_list_relay_devices', params: {'p_club_id': clubId}),
      );

  Future<Map<String, dynamic>?> relayDeviceForResource(
      String resourceId) async {
    final row = await client.rpc('app_relay_device_for_resource',
        params: {'p_resource_id': resourceId});
    return row is Map ? Map<String, dynamic>.from(row) : null;
  }

  Future<List<Map<String, dynamic>>> staff(String clubId) async => rowList(
        await client
            .from('club_members')
            .select('*, profiles(*), roles(*)')
            .eq('club_id', clubId)
            .order('created_at', ascending: true),
      );

  Future<List<Map<String, dynamic>>> payments(String clubId,
          {DateTime? from}) async =>
      rowList(await client
          .from('payments')
          .select('*, payment_methods(name,key,kind)')
          .eq('club_id', clubId)
          // .toUtc() matters: `from` is usually a local midnight built via
          // DateTime(y,m,d), and toIso8601String() on a non-UTC DateTime
          // omits the offset — Postgres then reads it as UTC, silently
          // shifting the boundary by the server's UTC offset (5h in
          // Tashkent) and dropping early-morning rows from "today".
          .gte('created_at', (from ?? DateTime(2000)).toUtc().toIso8601String())
          .order('created_at', ascending: false));

  Future<List<Map<String, dynamic>>> paymentMethods(String clubId) async =>
      rowList(await client
          .from('payment_methods')
          .select()
          .eq('club_id', clubId)
          .eq('active', true)
          .order('sort_order', ascending: true));

  Future<Map<String, dynamic>> startSession({
    required String clubId,
    required String resourceId,
    required String tariffId,
    String? customerId,
    int? plannedMinutes,
    int playersCount = 1,
    String? comment,
  }) async {
    final row = rowMap(await client.rpc('start_game_session', params: {
      'p_club_id': clubId,
      'p_resource_id': resourceId,
      'p_tariff_id': tariffId,
      'p_billing_mode': plannedMinutes == null ? 'POSTPAID' : 'PREPAID',
      'p_customer_id': customerId,
      'p_players_count': playersCount,
      'p_comment': comment,
      'p_prepaid_amount': 0,
      'p_planned_minutes': plannedMinutes,
    }));
    // A local COM-port hiccup must never block a session that's already
    // been created and billed for server-side -- the cashier can still
    // flip the relay by hand from the "Rele" page if this fails.
    try {
      await switchRelayDevice(row['relay_device'], true);
    } catch (_) {}
    return row;
  }

  Future<Map<String, dynamic>> finishSession(String sessionId) async {
    final row = rowMap(await client
        .rpc('finish_game_session', params: {'p_session_id': sessionId}));
    try {
      await switchRelayDevice(row['relay_device'], false);
    } catch (_) {}
    return row;
  }

  // A `direct_control` relay is USB-serial hardware plugged into this very
  // PC (see relay_controller.ino) -- Supabase's cloud dispatcher can never
  // reach it over HTTP, so start/finish switch it locally over the COM port
  // right after the RPC returns, instead of only enqueuing a cloud command
  // nothing ever drains. Also reused by RelayPage's manual on/off buttons.
  Future<void> switchRelayDevice(dynamic relayDevice, bool on,
      {int? channel}) async {
    if (relayDevice is! Map) return;
    if (relayDevice['provider'] != 'USB_SERIAL' ||
        relayDevice['direct_control'] != true) {
      return;
    }
    final config = relayDevice['configuration'];
    final port = config is Map ? config['port'] as String? : null;
    if (port == null || port.isEmpty) return;
    final resolvedChannel =
        channel ?? (relayDevice['channel'] as num?)?.toInt() ?? 1;
    final state = on ? 1 : 0;
    final checksum = (0xA0 + resolvedChannel + state) & 0xFF;
    await PrinterService.printRawToSerial(
        port, Uint8List.fromList([0xA0, resolvedChannel, state, checksum]));
  }

  Future<Map<String, dynamic>> extendSessionTimer(
          String sessionId, int minutes) async =>
      rowMap(await client.rpc('extend_session_timer', params: {
        'p_session_id': sessionId,
        'p_minutes': minutes,
      }));

  Future<Map<String, dynamic>> pauseSession(String sessionId) async => rowMap(
        await client.rpc('pause_game_session',
            params: {'p_session_id': sessionId, 'p_reason': null}),
      );

  Future<Map<String, dynamic>> resumeSession(String sessionId) async => rowMap(
        await client
            .rpc('resume_game_session', params: {'p_session_id': sessionId}),
      );

  Future<Map<String, dynamic>> sessionCurrentCharge(String sessionId) async =>
      rowMap(await client
          .rpc('session_current_charge', params: {'p_session_id': sessionId}));

  Future<Map<String, dynamic>> sessionNewRound(String sessionId,
          {String? note}) async =>
      rowMap(await client.rpc('session_new_round',
          params: {'p_session_id': sessionId, 'p_note': note}));

  Future<Map<String, dynamic>> createWalkinOrder(
          String clubId, String? customerId) async =>
      rowMap(await client.rpc('create_walkin_order', params: {
        'p_club_id': clubId,
        'p_customer_id': customerId,
      }));

  Future<void> addOrderItem(String orderId, String productId, num quantity) =>
      client.rpc('add_order_item', params: {
        'p_order_id': orderId,
        'p_product_id': productId,
        'p_quantity': quantity,
      });

  Future<void> removeOrderItem(String itemId, [num? quantity]) =>
      client.rpc('remove_order_item', params: {
        'p_item_id': itemId,
        'p_quantity': quantity,
      });

  Future<Map<String, dynamic>> orderJson(String orderId) async => rowMap(
        await client.rpc('app_order_json', params: {'p_order_id': orderId}),
      );

  Future<List<Map<String, dynamic>>> sessionRounds(String sessionId) async =>
      rowList(await client
          .from('session_rounds')
          .select()
          .eq('session_id', sessionId)
          .order('round_number', ascending: true));

  Future<Map<String, dynamic>> transferSession(
      String sessionId, String newResourceId) async {
    final row = rowMap(await client.rpc('transfer_game_session', params: {
      'p_session_id': sessionId,
      'p_new_resource_id': newResourceId,
      'p_reason': null,
    }));
    try {
      await switchRelayDevice(row['relay_device_off'], false);
      await switchRelayDevice(row['relay_device_on'], true);
    } catch (_) {}
    return row;
  }

  Future<Map<String, dynamic>> cancelSession(String sessionId) async => rowMap(
        await client.rpc('cancel_game_session', params: {
          'p_session_id': sessionId,
          'p_reason': 'Bekor qilindi (kassa)',
        }),
      );

  Future<void> setOrderCustomer(String orderId, String? customerId) =>
      client.rpc('set_order_customer', params: {
        'p_order_id': orderId,
        'p_customer_id': customerId,
      });

  Future<Map<String, dynamic>> applyDiscount(
    String orderId, {
    String? discountId,
    int? amount,
    String? reason,
  }) async =>
      rowMap(await client.rpc('apply_discount', params: {
        'p_order_id': orderId,
        'p_discount_id': discountId,
        'p_amount': amount,
        'p_reason': reason,
      }));

  Future<List<Map<String, dynamic>>> stockMovements(String clubId) async =>
      rowList(await client
          .from('stock_movements')
          .select('*, products(name)')
          .eq('club_id', clubId)
          .order('created_at', ascending: false)
          .limit(150));

  Future<Map<String, dynamic>> redeemPoints(String orderId, int points) async =>
      rowMap(await client.rpc('redeem_customer_points',
          params: {'p_order_id': orderId, 'p_points': points}));

  Future<Map<String, dynamic>> payOrder(
          String orderId, String paymentMethodId, int amount) async =>
      rowMap(await client.rpc('create_payment', params: {
        'p_order_id': orderId,
        'p_payments': [
          {'payment_method_id': paymentMethodId, 'amount': amount}
        ],
        'p_note': null,
      }));

  Future<void> relayCommand(String resourceId, bool on) => client.rpc(
        'relay_manual_command',
        params: {
          'p_resource_id': resourceId,
          'p_command': on ? 'ON' : 'OFF',
          'p_reason': 'Desktop manual control',
        },
      );

  RealtimeChannel subscribeClub(String clubId, void Function() refresh) {
    return client
        .channel('desktop:$clubId')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'resources',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'club_id',
              value: clubId),
          callback: (_) => refresh(),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'game_sessions',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'club_id',
              value: clubId),
          callback: (_) => refresh(),
        )
        // Bookings made through the bot/Mini App used to only surface here
        // via the notification bell's own 45s poll -- nothing woke it up
        // sooner, so a new reservation could take up to 45s to be noticed.
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'reservations',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'club_id',
              value: clubId),
          callback: (_) => refresh(),
        )
        // A customer registered or given a card/QR just now (via the bot or
        // admin panel) needs to show up in the cashier's list immediately --
        // otherwise scanning their new card reads as "not found" until
        // something unrelated happens to trigger a refresh.
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'customers',
          filter: PostgresChangeFilter(
              type: PostgresChangeFilterType.eq,
              column: 'club_id',
              value: clubId),
          callback: (_) => refresh(),
        )
        .subscribe();
  }
}
