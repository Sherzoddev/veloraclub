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
  RealtimeChannel? _channel;

  Future<void> initialize() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      context = await repository.loadContext();
      _channel = repository.subscribeClub(context!.clubId, refresh);
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
    revision++;
    notifyListeners();
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
    if (_channel != null) repository.client.removeChannel(_channel!);
    super.dispose();
  }
}
