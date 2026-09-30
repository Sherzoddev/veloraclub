import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart'
    show HapticFeedback, SystemSound, SystemSoundType, rootBundle;
import 'package:win32/win32.dart';

/// Plays a short notification chime for new low-stock/pending alerts.
///
/// Replaces `SystemSound.play(SystemSoundType.alert)`: that call only
/// triggers Windows' tiny built-in system beep (MessageBeep), which is quiet
/// and not something the app can change. This instead plays a bundled WAV
/// through PlaySoundW, which goes out over the real audio device at the
/// "System Sounds" volume -- noticeably louder, and an actual chime rather
/// than a beep.
Future<void> playNotificationSound() async {
  // PlaySoundW is Windows-only; elsewhere (Android) the system alert plus a
  // vibration is what a phone user expects anyway.
  if (!Platform.isWindows) {
    await SystemSound.play(SystemSoundType.alert);
    await HapticFeedback.vibrate();
    return;
  }
  final path = await _soundFilePath();
  if (path == null) return;
  final pathPtr = path.toNativeUtf16();
  try {
    PlaySound(
      PCWSTR(pathPtr),
      HMODULE(nullptr),
      SND_FLAGS(SND_FILENAME | SND_ASYNC | SND_NODEFAULT),
    );
  } finally {
    calloc.free(pathPtr);
  }
}

// PlaySoundW needs a real filesystem path, not a Flutter asset-bundle path --
// extracted to the temp dir once and reused for every later call.
String? _cachedPath;
Future<String?> _soundFilePath() async {
  final cached = _cachedPath;
  if (cached != null && File(cached).existsSync()) return cached;
  try {
    final bytes = await rootBundle.load('assets/sounds/notify.wav');
    final file = File('${Directory.systemTemp.path}\\velora_notify.wav');
    await file.writeAsBytes(bytes.buffer.asUint8List(), flush: true);
    _cachedPath = file.path;
    return file.path;
  } catch (_) {
    return null;
  }
}
