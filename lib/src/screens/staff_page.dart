import 'dart:math';

import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class StaffPage extends StatelessWidget {
  const StaffPage({super.key, required this.controller});
  final ClubController controller;
  @override
  Widget build(BuildContext context) => Padding(
      padding: pagePadding(context),
      child: Column(children: [
        PageHeader(title: 'Xodimlar', actions: [
          FilledButton.icon(
              onPressed: () => _add(context),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Xodim qo\'shish'))
        ]),
        const SizedBox(height: 24),
        Expanded(
            child: AsyncPane<List<Map<String, dynamic>>>(
                future: controller.repository.staff(controller.context!.clubId),
                builder: (context, rows) => ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) {
                      final m = rows[i], p = m['profiles'], r = m['roles'];
                      final owner = r is Map && r['is_owner'] == true;
                      return VCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          child: Row(children: [
                            Expanded(
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                  Text(
                                      '${p is Map ? p['full_name'] : m['employee_code'] ?? 'Xodim'}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 18)),
                                  Text('${r is Map ? r['name'] : ''}',
                                      style: TextStyle(color: VColors.muted))
                                ])),
                            if (owner)
                              Pill('Egasi',
                                  color: VColors.field,
                                  foreground: VColors.muted)
                            else ...[
                              IconButton(
                                  onPressed: () => _edit(context, m),
                                  icon: const Icon(Icons.edit_outlined)),
                              Switch(
                                  value: m['active'] == true,
                                  onChanged: (v) => _toggle(context, m, v)),
                              IconButton(
                                  onPressed: () => _delete(context, m),
                                  icon: Icon(Icons.delete_outline_rounded,
                                      color: VColors.red))
                            ]
                          ]));
                    })))
      ]));
  Future<void> _toggle(
      BuildContext context, Map<String, dynamic> m, bool v) async {
    try {
      await controller.repository.client
          .from('club_members')
          .update({'active': v}).eq('id', m['id']);
      controller.refresh();
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _delete(BuildContext context, Map<String, dynamic> m) async {
    final p = m['profiles'];
    final name = p is Map ? '${p['full_name']}' : 'Xodim';
    final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                scrollable: true,
                title: const Text('Xodimni bazadan o\'chirish?'),
                content: Text(
                    '$name butunlay o\'chiriladi. Bu amalni qaytarib bo\'lmaydi.'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Bekor qilish')),
                  FilledButton(
                      style:
                          FilledButton.styleFrom(backgroundColor: VColors.red),
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('O\'chirish'))
                ]));
    if (ok != true) return;
    try {
      await controller.repository.client
          .from('club_members')
          .delete()
          .eq('id', m['id']);
      controller.refresh();
      if (context.mounted) showDone(context, 'Xodim o\'chirildi');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  Future<void> _edit(BuildContext context, Map<String, dynamic> m) async {
    final p = m['profiles'];
    final userId = '${m['user_id']}';
    final name =
        TextEditingController(text: p is Map ? '${p['full_name'] ?? ''}' : '');
    final pin = TextEditingController();
    bool busy = false;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Xodimni tahrirlash'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Ism')),
                const SizedBox(height: 10),
                TextField(
                  controller: pin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration: const InputDecoration(
                      labelText: 'Yangi PIN-kod',
                      hintText: 'O\'zgartirmaslik uchun bo\'sh qoldiring'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Bekor qilish')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final trimmedName = name.text.trim();
                      final trimmedPin = pin.text.trim();
                      if (trimmedName.isEmpty) {
                        showError(context, Exception('Ism kiritilishi shart'));
                        return;
                      }
                      if (trimmedPin.isNotEmpty &&
                          !RegExp(r'^\d{4,6}$').hasMatch(trimmedPin)) {
                        showError(context,
                            Exception('PIN 4-6 xonali raqam bo\'lishi kerak'));
                        return;
                      }
                      setState(() => busy = true);
                      try {
                        final clubId = controller.context!.clubId;
                        await controller.repository.client
                            .rpc('rename_staff_member', params: {
                          'p_user_id': userId,
                          'p_club_id': clubId,
                          'p_full_name': trimmedName,
                        });
                        if (trimmedPin.isNotEmpty) {
                          await controller.repository.client
                              .rpc('set_staff_pin', params: {
                            'p_user_id': userId,
                            'p_club_id': clubId,
                            'p_pin': trimmedPin,
                          });
                        }
                        if (context.mounted) Navigator.pop(context);
                        controller.refresh();
                      } catch (e) {
                        setState(() => busy = false);
                        if (context.mounted) showError(context, e);
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Saqlash'),
            ),
          ],
        ),
      ),
    );
  }

  static String _randomToken(int length) {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random.secure();
    return List.generate(length, (_) => chars[rnd.nextInt(chars.length)])
        .join();
  }

  Future<void> _add(BuildContext context) async {
    final name = TextEditingController();
    final pin = TextEditingController();
    String role = 'cashier';
    bool busy = false;

    await showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          scrollable: true,
          title: const Text('Yangi xodim'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                    controller: name,
                    autofocus: true,
                    decoration: const InputDecoration(labelText: 'Ism')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: role,
                  decoration: const InputDecoration(labelText: 'Rol'),
                  items: const [
                    DropdownMenuItem(value: 'cashier', child: Text('Kassir')),
                    DropdownMenuItem(value: 'admin', child: Text('Admin')),
                  ],
                  onChanged: (v) => setState(() => role = v ?? role),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: pin,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  decoration:
                      const InputDecoration(labelText: 'PIN-kod (4 raqam)'),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Xodim faqat shu kompyuterda shu PIN-kod bilan kiradi',
                    style: TextStyle(color: VColors.subtle, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('Bekor qilish')),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      if (name.text.trim().isEmpty ||
                          !RegExp(r'^\d{4,6}$').hasMatch(pin.text.trim())) {
                        showError(context,
                            Exception('Ism va 4-6 xonali PIN kiriting'));
                        return;
                      }
                      setState(() => busy = true);
                      try {
                        final clubId = controller.context!.clubId;
                        final email =
                            'staff+${clubId.substring(0, 8)}.${_randomToken(10)}@velora.local';
                        final password = _randomToken(24);
                        final result = await controller
                            .repository.client.functions
                            .invoke('create-staff-account', body: {
                          'club_id': clubId,
                          'email': email,
                          'password': password,
                          'full_name': name.text.trim(),
                          'role_key': role,
                        });
                        final userId = (result.data as Map?)?['user_id'];
                        if (userId == null) {
                          throw Exception('Xodim yaratilmadi');
                        }
                        await controller.repository.client
                            .rpc('set_staff_pin', params: {
                          'p_user_id': userId,
                          'p_club_id': clubId,
                          'p_pin': pin.text.trim(),
                        });
                        if (context.mounted) Navigator.pop(context);
                        controller.refresh();
                      } catch (e) {
                        setState(() => busy = false);
                        if (context.mounted) showError(context, e);
                      }
                    },
              child: busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Yaratish'),
            ),
          ],
        ),
      ),
    );
  }
}
