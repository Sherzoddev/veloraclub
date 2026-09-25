import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'data/club_repository.dart';
import 'i18n.dart';
import 'screens/dashboard_shell.dart';
import 'screens/login_page.dart';
import 'state/club_controller.dart';
import 'theme.dart';

class VeloraApp extends StatelessWidget {
  const VeloraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge(
          [ThemeController.instance, LocaleController.instance]),
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Velora Club',
        theme: buildTheme(),
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  late final StreamSubscription<AuthState> _auth;
  Session? _session;

  @override
  void initState() {
    super.initState();
    final client = Supabase.instance.client;
    _session = client.auth.currentSession;
    _auth = client.auth.onAuthStateChange.listen((event) {
      if (mounted) setState(() => _session = event.session);
    });
  }

  @override
  void dispose() {
    _auth.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session == null) return const LoginPage();
    return _ClubBoot(key: ValueKey(_session!.user.id));
  }
}

class _ClubBoot extends StatefulWidget {
  const _ClubBoot({super.key});

  @override
  State<_ClubBoot> createState() => _ClubBootState();
}

class _ClubBootState extends State<_ClubBoot> {
  late final ClubController controller;

  @override
  void initState() {
    super.initState();
    controller = ClubController(ClubRepository())..initialize();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (controller.loading) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (controller.error != null || controller.context == null) {
          return Scaffold(
            body: Center(
              child: SizedBox(
                width: 520,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 52, color: VColors.red),
                        const SizedBox(height: 18),
                        Text(tr('Klubni ochib bo\'lmadi'),
                            style: Theme.of(context).textTheme.headlineSmall),
                        const SizedBox(height: 8),
                        Text('${controller.error}',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: VColors.muted)),
                        const SizedBox(height: 24),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            OutlinedButton(
                              onPressed: () =>
                                  Supabase.instance.client.auth.signOut(),
                              child: Text(tr('Chiqish')),
                            ),
                            const SizedBox(width: 12),
                            FilledButton(
                              onPressed: controller.initialize,
                              child: Text(tr('Qayta urinish')),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return DashboardShell(controller: controller);
      },
    );
  }
}
