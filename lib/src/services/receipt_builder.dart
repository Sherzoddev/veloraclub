// Turns an order (or an X-report) into the actual bytes sent to the
// printer, using the club's receipt customization from `clubs` (Sozlamalar →
// Chek): title, subtitle line, footer line, QR link/caption, paper width.

import 'dart:typed_data';

import '../utils.dart';
import 'esc_pos_builder.dart';

/// [kind] distinguishes a game-time segment ('time', printed under the
/// "ORALIQ VAQTLAR" breakdown with its own start/end clock) from a sold
/// product ('product', the default).
class ReceiptLine {
  const ReceiptLine(this.label, this.amount,
      {this.quantity,
      this.cost,
      this.note,
      this.kind = 'product',
      this.startedAt,
      this.endedAt});
  final String label;
  final num? quantity;
  final int amount;
  final int? cost;
  final String? note;
  final String kind;
  final DateTime? startedAt;
  final DateTime? endedAt;
}

int _charsPerLine(int paperWidthMm) => paperWidthMm >= 80 ? 48 : 32;

String _clock(DateTime d) {
  final l = d.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

String _clockWithSeconds(DateTime d) {
  final l = d.toLocal();
  return '${_clock(d)}:${l.second.toString().padLeft(2, '0')}';
}

String _durationPrecise(Duration d) {
  final m = d.inMinutes, s = d.inSeconds % 60;
  return '$m daqiqa $s soniya';
}

/// Right-aligns [right] against [left] within [width] characters, trimming
/// [left] first if the two would otherwise collide — a plain product name
/// next to a six-digit sum is the normal case this guards against.
String _twoColumn(String left, String right, int width) {
  final space = width - right.length;
  if (space <= 0) return right;
  if (left.length > space) left = '${left.substring(0, space - 1)}…';
  return left + ' ' * (space - left.length) + right;
}

Uint8List buildOrderReceipt({
  required Map<String, dynamic> club,
  required String cashierName,
  String? resourceName,
  num? pricePerHour,
  String? familyLabel,
  DateTime? sessionStartedAt,
  DateTime? sessionEndedAt,
  required int receiptNumber,
  required DateTime date,
  required List<ReceiptLine> items,
  int? subtotal,
  int? discount,
  required int total,
  required String paymentMethodName,
  bool printCost = false,
}) {
  final paperMm = (club['receipt_paper_mm'] as num?)?.toInt() ?? 58;
  final width = _charsPerLine(paperMm);
  final b = EscPosBuilder();

  final title = (club['receipt_header'] as String?)?.trim().isNotEmpty == true
      ? club['receipt_header'] as String
      : (club['name'] as String? ?? 'Klub');
  b.align(EscAlign.center)
    ..bold(true)
    ..size(wide: true)
    ..text(title)
    ..size()
    ..bold(false);

  final subtitle = club['receipt_subtitle'] as String?;
  if (subtitle != null && subtitle.trim().isNotEmpty) b.text(subtitle);
  final phone = club['receipt_phone'] as String?;
  if (phone != null && phone.trim().isNotEmpty) b.text(phone);

  final isoDate = '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
  b
    ..divider(width)
    ..text('Sana: $isoDate')
    ..bold(true)
    ..text('Chek №$receiptNumber')
    ..bold(false)
    ..align(EscAlign.left)
    ..text('Kassir: $cashierName');
  if (sessionStartedAt != null) {
    b.text('Boshlanishi: ${_clockWithSeconds(sessionStartedAt)}');
  }
  if (sessionEndedAt != null) {
    b.text('Tugash: ${_clockWithSeconds(sessionEndedAt)}');
  }
  if (sessionStartedAt != null && sessionEndedAt != null) {
    b.text('Davomiylik: '
        '${_durationPrecise(sessionEndedAt.difference(sessionStartedAt))}');
  }

  if (resourceName != null) {
    b.divider(width).text('Stol: $resourceName');
    if (pricePerHour != null) {
      b.text('Soatlik narx: ${money(pricePerHour)}/soat');
    }
  }

  final timeLines = items.where((i) => i.kind == 'time').toList();
  final productLines = items.where((i) => i.kind != 'time').toList();

  if (timeLines.isNotEmpty) {
    final timeTotal = timeLines.fold<int>(0, (s, l) => s + l.amount);
    b
      ..divider(width)
      ..bold(true)
      ..text((familyLabel ?? 'Vaqt').toUpperCase())
      ..bold(false)
      ..text('Narxi: ${money(timeTotal)}')
      ..divider(width)
      ..text('ORALIQ VAQTLAR');
    for (final l in timeLines) {
      if (l.startedAt != null && l.endedAt != null) {
        final mins = l.endedAt!.difference(l.startedAt!).inMinutes;
        b.text(_twoColumn(
            '${_clock(l.startedAt!)} - ${_clock(l.endedAt!)} ($mins min)',
            money(l.amount), width));
      } else {
        final qtyPrefix = l.quantity != null ? '${l.quantity} x ' : '';
        b.text(_twoColumn('$qtyPrefix${l.label}', money(l.amount), width));
      }
      if (l.note != null && l.note!.trim().isNotEmpty) b.text('  ${l.note}');
    }
  }

  if (productLines.isNotEmpty) {
    b
      ..divider(width)
      ..bold(true)
      ..text('TOVARLAR')
      ..bold(false);
    for (final item in productLines) {
      final qtyPrefix = item.quantity != null ? '${item.quantity} x ' : '';
      b.text(_twoColumn('$qtyPrefix${item.label}', money(item.amount), width));
      if (item.note != null && item.note!.trim().isNotEmpty) {
        b.text('  ${item.note}');
      }
      if (printCost && item.cost != null) {
        b.text('  tannarx: ${money(item.cost!)}');
      }
    }
  }

  b.divider(width);
  if (discount != null && discount > 0) {
    b
      ..text(_twoColumn('Oraliq summa', money(subtotal ?? total + discount), width))
      ..text(_twoColumn('Chegirma', '-${money(discount)}', width));
  }
  b
    ..bold(true)
    ..size(tall: true)
    ..text(_twoColumn('JAMI', money(total), width))
    ..size()
    ..bold(false)
    ..text('To\'lov: $paymentMethodName')
    ..divider(width);

  final footer = club['receipt_footer'] as String?;
  b.align(EscAlign.center);
  if (footer != null && footer.trim().isNotEmpty) b.text(footer);

  if (club['receipt_qr_enabled'] == true) {
    final qrUrl = club['receipt_qr_url'] as String?;
    if (qrUrl != null && qrUrl.trim().isNotEmpty) {
      b.divider(width);
      final caption = club['receipt_qr_caption'] as String?;
      if (caption != null && caption.trim().isNotEmpty) b.text(caption);
      b.feed(1)..qrCode(qrUrl)..feed(1);
    }
  }

  b.feed(3).cut();
  return b.build();
}

Uint8List buildShiftXReport({
  required Map<String, dynamic> club,
  required String cashierName,
  required DateTime openedAt,
  required Map<String, dynamic> totals,
}) {
  final paperMm = (club['receipt_paper_mm'] as num?)?.toInt() ?? 58;
  final width = _charsPerLine(paperMm);
  final b = EscPosBuilder();

  b.align(EscAlign.center)
    ..bold(true)
    ..text('X-HISOBOT')
    ..bold(false)
    ..text('${club['name'] ?? ''}')
    ..divider(width)
    ..align(EscAlign.left)
    ..text('Kassir: $cashierName')
    ..text('Ochilgan: ${shortDate(openedAt.toIso8601String())}')
    ..text('Hisobot: ${shortDate(DateTime.now().toIso8601String())}')
    ..divider(width);

  void row(String label, dynamic value) =>
      b.text(_twoColumn(label, money(value), width));

  row('Buyurtmalar', totals['orders_count'] ?? 0);
  row('Naqd', totals['cash']);
  row('Karta', totals['card'] ?? totals['uzcard']);
  row('Perevod', totals['transfer']);
  row('Qarz', totals['debt']);
  b.divider(width);
  row('Tushum', totals['revenue'] ?? totals['total']);
  row('Tannarx', totals['cost']);
  row('Foyda', totals['profit']);
  row('Xarajatlar', totals['expenses']);
  b
    ..bold(true)
    ..text(_twoColumn(
        'Sof foyda', money(totals['net_profit']), width))
    ..bold(false)
    ..divider(width)
    ..align(EscAlign.center)
    ..text('Smena hali ochiq')
    ..feed(3)
    ..cut();

  return b.build();
}
