import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/env.dart';
import 'src/i18n.dart';
import 'src/services/device_access_service.dart';
import 'src/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final preferences = await SharedPreferences.getInstance();
  final venueToken = preferences.getString(DeviceAccessService.venueTokenKey);
  await ThemeController.instance.load();
  await LocaleController.instance.load();
  await Supabase.initialize(
    url: supabaseUrl,
    publishableKey: supabasePublishableKey,
    headers: venueToken == null || venueToken.isEmpty
        ? null
        : {'x-venue-token': venueToken},
  );
  await windowManager.ensureInitialized();
  final options = WindowOptions(
    size: const Size(1440, 900),
    minimumSize: const Size(1120, 700),
    center: true,
    title: 'Velora Club',
    backgroundColor: VColors.bg,
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(const VeloraApp());
}
