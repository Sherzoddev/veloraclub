import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'theme.dart';

final _money = NumberFormat.decimalPattern('ru_RU');

String money(dynamic value) {
  final number = value is num ? value : num.tryParse('$value') ?? 0;
  return '${_money.format(number).replaceAll('\u00a0', ' ')} so\'m';
}

String shortDate(dynamic value) {
  if (value == null) return '—';
  final parsed = DateTime.tryParse('$value')?.toLocal();
  return parsed == null ? '$value' : DateFormat('dd.MM, HH:mm').format(parsed);
}

// A USB barcode/QR scanner emulates a keyboard, typing by physical key
// position. If Windows' active input layout is Russian (ЙЦУКЕН) instead of
// Latin when a scan lands in a text field, every Latin letter in the
// scanned token ("CARD:...", a card uuid) comes out as the Cyrillic letter
// that shares that physical key -- e.g. "CARD:" becomes "СФКВЖ". This maps
// each Cyrillic character back to the Latin one on the same key, so a scan
// still resolves correctly no matter which layout was active.
const Map<String, String> _yicukenToLatin = {
  'й': 'q', 'ц': 'w', 'у': 'e', 'к': 'r', 'е': 't', 'н': 'y', 'г': 'u',
  'ш': 'i', 'щ': 'o', 'з': 'p', 'х': '[', 'ъ': ']',
  'ф': 'a', 'ы': 's', 'в': 'd', 'а': 'f', 'п': 'g', 'р': 'h', 'о': 'j',
  'л': 'k', 'д': 'l', 'ж': ';', 'э': "'",
  'я': 'z', 'ч': 'x', 'с': 'c', 'м': 'v', 'и': 'b', 'т': 'n', 'ь': 'm',
  'б': ',', 'ю': '.',
  'Й': 'Q', 'Ц': 'W', 'У': 'E', 'К': 'R', 'Е': 'T', 'Н': 'Y', 'Г': 'U',
  'Ш': 'I', 'Щ': 'O', 'З': 'P', 'Х': '{', 'Ъ': '}',
  'Ф': 'A', 'Ы': 'S', 'В': 'D', 'А': 'F', 'П': 'G', 'Р': 'H', 'О': 'J',
  'Л': 'K', 'Д': 'L', 'Ж': ':', 'Э': '"',
  'Я': 'Z', 'Ч': 'X', 'С': 'C', 'М': 'V', 'И': 'B', 'Т': 'N', 'Ь': 'M',
  'Б': '<', 'Ю': '>',
};

String fixScannerLayout(String input) =>
    input.split('').map((ch) => _yicukenToLatin[ch] ?? ch).join();

String durationFrom(dynamic value) {
  final date = DateTime.tryParse('$value')?.toLocal();
  if (date == null) return '0 daq';
  final d = DateTime.now().difference(date);
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  return h > 0 ? '$h soat $m daq' : '$m daq';
}

// A compact floating toast in the bottom-left corner instead of the default
// SnackBar's edge-to-edge bar -- the default `behavior: fixed` (no shape, no
// margin) stretches the full width of the window, which on a desktop-sized
// screen reads as a jarring bar rather than a toast.
void _toast(BuildContext context, {required Color color, required IconData icon, required String message}) {
  ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(
      SnackBar(
        backgroundColor: color,
        behavior: SnackBarBehavior.floating,
        width: 420,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
        content: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
}

void showError(BuildContext context, Object error) {
  final raw = error.toString().replaceFirst('Exception: ', '');
  final message = raw.contains('RESOURCE_ALREADY_BUSY')
      ? 'Bu stol allaqachon band. Ma\'lumot yangilanmoqda.'
      : raw.contains('NO_OPEN_SHIFT')
          ? 'Avval smenani oching.'
          : raw;
  _toast(context, color: VColors.red, icon: Icons.error_outline_rounded, message: message);
}

void showDone(BuildContext context, String message) {
  _toast(context, color: VColors.greenDark, icon: Icons.check_circle_rounded, message: message);
}

Map<String, dynamic> rowMap(dynamic value) =>
    Map<String, dynamic>.from(value as Map);

List<Map<String, dynamic>> rowList(dynamic value) =>
    (value as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
