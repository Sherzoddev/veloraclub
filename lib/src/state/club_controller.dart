import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/club_repository.dart';

class ClubController extends ChangeNotifier {
  ClubController(this.repository);

  final ClubRepository repository;
  ClubContextData? context;
  bool loading = true;
  Object? error;
  int page = 0;
  bool sidebarExpanded = true;
  int revision = 0;

  /// Bumped when a customer (or their coupon) changes: the cached customer
  /// lists in the pickers are thrown away, so a client who has just joined
  /// through the bot can be found within a second.
  int customersRevision = 0;
  RealtimeChannel? _channel;

  Future<void> initialize() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      context = await repository.loadContext();
      _channel = repository.subscribeClub(context!.clubId, _refreshSoon,
          onCustomers: () => customersRevision++);
    } catch (e) {
      error = e;
    } finally {
      loading = false;
      notifyListeners();
    }
  }

  void go(int value) {
    page = value;
    notifyListeners();
  }

  void toggleSidebar() {
    sidebarExpanded = !sidebarExpanded;
    notifyListeners();
  }

  void refresh() {
    _debounce?.cancel();
    revision++;
    notifyListeners();
  }

  /// The app itself added or changed a customer.
  void customersChanged() {
    customersRevision++;
    refresh();
  }

  Timer? _debounce;

  /// Realtime sends several events for one change (starting a table touches
  /// the session, the table and the order): they come within a fraction of a
  /// second and used to start as many full reloads. One is enough.
  void _refreshSoon() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), refresh);
  }

  /// Refetches `context.club`/`member`/`role`/`profile` from the DB — needed
  /// after any write to the `clubs` row, since `context` is otherwise only
  /// loaded once at startup and `refresh()` alone won't pick up the change.
  Future<void> reloadContext() async {
    context = await repository.loadContext();
    revision++;
    notifyListeners();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    if (_channel != null) repository.client.removeChannel(_channel!);
    super.dispose();
  }
}
