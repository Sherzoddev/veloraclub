import 'package:flutter/material.dart';

import '../state/club_controller.dart';
import '../theme.dart';
import '../utils.dart';
import '../widgets/common.dart';

class RelayPage extends StatelessWidget {
  const RelayPage({super.key, required this.controller});
  final ClubController controller;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          children: [
            PageHeader(
              title: 'Rele',
              actions: [
                IconButton(
                  onPressed: controller.refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Expanded(
              child: AsyncPane<List<dynamic>>(
                future: Future.wait([
                  controller.repository
                      .relayDevices(controller.context!.clubId),
                  controller.repository.resources(controller.context!.clubId),
                ]),
                builder: (context, data) {
                  final devices = data[0] as List<Map<String, dynamic>>;
                  final resources = data[1] as List<Map<String, dynamic>>;
                  if (devices.isEmpty) {
                    return const EmptyState(
                      icon: Icons.settings_remote_outlined,
                      title: 'Rele ulanmagan',
                      subtitle: 'Sozlamalarda yangi rele qo\'shing',
                    );
                  }
                  return ListView(
                    children: devices.map((device) {
                      final linked = resources
                          .where((r) => r['relay_device_id'] == device['id'])
                          .toList();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: VCard(
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    device['provider'] == 'USB_SERIAL'
                                        ? Icons.usb_rounded
                                        : Icons.wifi_rounded,
                                    color: VColors.green,
                                    size: 28,
                                  ),
                                  const SizedBox(width: 12),
                                  Text('${device['name']}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                          fontSize: 19)),
                                  const SizedBox(width: 12),
                                  Pill('${device['provider']}',
                                      color: VColors.field,
                                      foreground: VColors.muted),
                                  const Spacer(),
                                  Text(
                                    '${device['status'] ?? 'OFFLINE'}',
                                    style: TextStyle(
                                      color: device['status'] == 'ONLINE'
                                          ? VColors.green
                                          : VColors.muted,
                                    ),
                                  ),
                                ],
                              ),
                              if (linked.isNotEmpty) ...[
                                const SizedBox(height: 16),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    children: linked
                                        .map((resource) => _RelayControl(
                                              resource: resource,
                                              onCommand: (on) => _command(
                                                  context, device, resource, on),
                                            ))
                                        .toList(),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),
          ],
        ),
      );

  Future<void> _command(BuildContext context, Map<String, dynamic> device,
      Map<String, dynamic> resource, bool on) async {
    try {
      final channel = (resource['relay_channel'] as num?)?.toInt() ?? 1;
      await controller.repository
          .switchRelayDevice(device, on, channel: channel);
      await controller.repository.relayCommand('${resource['id']}', on);
      if (context.mounted) {
        showDone(
            context, '${resource['name']}: ${on ? 'yoqildi' : 'o\'chirildi'}');
      }
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }
}

class _RelayControl extends StatelessWidget {
  const _RelayControl({required this.resource, required this.onCommand});
  final Map<String, dynamic> resource;
  final ValueChanged<bool> onCommand;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: VColors.field,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${resource['name']}'),
            const SizedBox(width: 10),
            OutlinedButton(
                onPressed: () => onCommand(true), child: const Text('Yoqish')),
            const SizedBox(width: 5),
            OutlinedButton(
                onPressed: () => onCommand(false),
                child: const Text('O\'chirish')),
          ],
        ),
      );
}
