import 'package:flutter/material.dart';

import '../theme.dart';
import '../utils.dart';
import 'common.dart';

/// Shared "Mijozni tanlash" dialog — used from the sales cart and from the
/// session payment sheet alike, so both pick a customer the same way.
/// Returns the chosen customer's id, or null if the dialog was dismissed.
///
/// The search field doubles as a scanner input. New member cards encode the
/// unpredictable `CARD:<card_token>` value. Legacy `CUST:<customer uuid>`
/// cards and bare phone numbers remain readable during the transition.
Future<String?> pickCustomer(
  BuildContext context,
  List<Map<String, dynamic>> customers,
) {
  final search = TextEditingController();
  String query = '';
  return showDialog<String?>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final digits = query.replaceAll(RegExp(r'\D'), '');
        final filtered = query.isEmpty
            ? customers
            : customers.where((c) {
                final name = '${c['full_name'] ?? ''}'.toLowerCase();
                final phone = '${c['phone'] ?? ''}';
                if (name.contains(query.toLowerCase())) return true;
                if (digits.isNotEmpty &&
                    phone.replaceAll(RegExp(r'\D'), '').contains(digits)) {
                  return true;
                }
                return false;
              }).toList();
        return AlertDialog(
          title: const Text('Mijozni tanlash'),
          content: SizedBox(
            width: 520,
            height: 520,
            child: Column(
              children: [
                SearchBox(
                  hint: 'Ism, telefon — yoki kartani skaner qiling',
                  controller: search,
                  autofocus: true,
                  onChanged: (v) => setState(() => query = v),
                  onSubmitted: (v) {
                    final scanned = fixScannerLayout(v.trim());
                    if (scanned.isEmpty) return;

                    if (scanned.toUpperCase().startsWith('CARD:')) {
                      final token = scanned.substring(5).trim().toLowerCase();
                      final byToken = customers.where((c) {
                        return '${c['card_token'] ?? ''}'.toLowerCase() ==
                            token;
                      }).toList();
                      if (byToken.isNotEmpty) {
                        Navigator.pop(context, '${byToken.first['id']}');
                      }
                      return;
                    }

                    // Legacy card format kept for already-issued QR cards.
                    if (scanned.toUpperCase().startsWith('CUST:')) {
                      final id = scanned.substring(5).trim();
                      final byId =
                          customers.where((c) => '${c['id']}' == id).toList();
                      if (byId.isNotEmpty) {
                        Navigator.pop(context, '${byId.first['id']}');
                      }
                      return;
                    }

                    // Fallback: a bare phone number, in case a club prints
                    // its own phone-based cards instead of the bot's QR.
                    final scannedDigits = scanned.replaceAll(RegExp(r'\D'), '');
                    if (scannedDigits.isEmpty) return;
                    final byPhone = customers.where((c) {
                      final phone =
                          '${c['phone'] ?? ''}'.replaceAll(RegExp(r'\D'), '');
                      return phone.isNotEmpty && phone == scannedDigits;
                    }).toList();
                    if (byPhone.length == 1) {
                      Navigator.pop(context, '${byPhone.first['id']}');
                    }
                  },
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: filtered.isEmpty
                      ? Center(
                          child: Text('Mijoz topilmadi',
                              style: TextStyle(color: VColors.subtle)))
                      : ListView(
                          children: filtered
                              .map((c) => ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: VColors.greenSoft,
                                      child: Icon(Icons.person_outline_rounded,
                                          color: VColors.green),
                                    ),
                                    title: Text('${c['full_name'] ?? 'Mijoz'}'),
                                    subtitle: Text(_subtitle(c)),
                                    onTap: () =>
                                        Navigator.pop(context, '${c['id']}'),
                                  ))
                              .toList(),
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Bekor qilish')),
          ],
        );
      },
    ),
  );
}

String _subtitle(Map<String, dynamic> c) {
  final parts = <String>[];
  final phone = '${c['phone'] ?? ''}';
  if (phone.isNotEmpty) parts.add(phone);
  final tier = c['loyalty_tiers'];
  if (tier is Map) {
    if (tier['name'] != null) parts.add('${tier['name']}');
    if (tier['discount_percent'] != null) {
      parts.add('${tier['discount_percent']}%');
    }
  }
  parts.add('${c['bonus_points'] ?? 0} ball');
  return parts.join(' · ');
}
