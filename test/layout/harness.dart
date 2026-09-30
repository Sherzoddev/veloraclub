// Shared setup for the layout tests: real Roboto + Material Icons (from the
// Flutter SDK) instead of the test font's boxes, so text measures -- and
// wraps or overflows -- exactly like on a device.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:velora_club/src/data/club_repository.dart';
import 'package:velora_club/src/state/club_controller.dart';

import 'fake_backend.dart' as fake;

final String _fontDir = () {
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable)
          .parent
          .parent
          .parent
          .parent
          .parent
          .parent
          .path;
  return '$flutterRoot/bin/cache/artifacts/material_fonts';
}();

// google_fonts asks for its own file names; the SDK ships a subset of the
// weights, so the missing ones map to the next *heavier* one (wider text --
// the safe side for overflow checks).
const _robotoFiles = {
  'Roboto-Thin': 'Roboto-Thin.ttf',
  'Roboto-ExtraLight': 'Roboto-Light.ttf',
  'Roboto-Light': 'Roboto-Light.ttf',
  'Roboto-Regular': 'Roboto-Regular.ttf',
  'Roboto-Medium': 'Roboto-Medium.ttf',
  'Roboto-SemiBold': 'Roboto-Bold.ttf',
  'Roboto-Bold': 'Roboto-Bold.ttf',
  'Roboto-ExtraBold': 'Roboto-Black.ttf',
  'Roboto-Black': 'Roboto-Black.ttf',
  'Roboto-Italic': 'Roboto-Italic.ttf',
  'Roboto-MediumItalic': 'Roboto-MediumItalic.ttf',
  'Roboto-BoldItalic': 'Roboto-BoldItalic.ttf',
};

Future<void> setUpLayoutTests() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  GoogleFonts.config.allowRuntimeFetching = false;

  final manifest = <String, Object>{
    for (final name in _robotoFiles.keys)
      'fonts/$name.ttf': [
        {'asset': 'fonts/$name.ttf'}
      ],
    'assets/sounds/notify.wav': [
      {'asset': 'assets/sounds/notify.wav'}
    ],
  };
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMessageHandler('flutter/assets', (message) async {
    final key = Uri.decodeFull(const StringCodec().decodeMessage(message)!);
    if (key == 'AssetManifest.bin') {
      return const StandardMessageCodec().encodeMessage(manifest);
    }
    if (key.startsWith('fonts/')) {
      final name = key.substring('fonts/'.length, key.length - '.ttf'.length);
      final bytes = File('$_fontDir/${_robotoFiles[name]}').readAsBytesSync();
      return ByteData.view(bytes.buffer);
    }
    final file = File(key);
    if (file.existsSync()) return ByteData.view(file.readAsBytesSync().buffer);
    return null;
  });

  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(
          ByteData.view(File('$_fontDir/$f').readAsBytesSync().buffer)));
    }
    await loader.load();
  }

  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
  await load('Roboto', [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
    'Roboto-Black.ttf'
  ]);
}

ClubController fakeController({int page = 0, String role = 'owner'}) {
  final client = SupabaseClient(
    'https://test.supabase.co',
    'test-key',
    httpClient: fake.fakeSupabaseHttp(),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );
  final roleRow = fake.roles.firstWhere((r) => r['key'] == role);
  return ClubController(ClubRepository(client))
    ..context = ClubContextData(
      club: fake.club,
      member: {...fake.member, 'roles': roleRow},
      role: roleRow,
      profile: fake.profile,
    )
    ..loading = false
    ..page = page;
}

/// Collects every layout problem Flutter reports (RenderFlex overflow,
/// unbounded constraints, …) instead of failing on the first one.
class LayoutErrors {
  final List<String> errors = [];
  FlutterExceptionHandler? _previous;

  void start() {
    _previous = FlutterError.onError;
    FlutterError.onError = (details) {
      final text = details.toString(minLevel: DiagnosticLevel.info);
      final source = '$text\n${details.stack ?? ''}';
      final where =
          RegExp(r'(?:file://[^\s)]*/lib/|package:velora_club/)([^\s):]+:\d+)')
                  .firstMatch(source)
                  ?.group(1) ??
              '?';
      final first = details.exceptionAsString().split('\n').first;
      errors.add('$first  @ lib/$where');
    };
  }

  void stop() => FlutterError.onError = _previous;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 250)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}
