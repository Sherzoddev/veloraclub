import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_access_service.dart';
import '../theme.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final service = DeviceAccessService();
  final activationCode = TextEditingController();
  final venueToken = TextEditingController();
  final pin = TextEditingController();

  DeviceAccessSnapshot? snapshot;
  bool busy = false;
  String? error;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  @override
  void dispose() {
    activationCode.dispose();
    venueToken.dispose();
    pin.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final value = await service.initialize();
      if (mounted) setState(() => snapshot = value);
    } catch (exception) {
      if (mounted) {
        setState(() => error = DeviceAccessService.readableError(exception));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _activate() async {
    if (activationCode.text.trim().isEmpty || venueToken.text.trim().isEmpty) {
      setState(() => error = 'Faollashtirish kodi va venue tokenni kiriting.');
      return;
    }
    await _run(() async {
      final value = await service.activateAndConnect(
        activationCode: activationCode.text,
        venueToken: venueToken.text,
      );
      if (mounted) setState(() => snapshot = value);
    });
  }

  Future<void> _connect() async {
    if (venueToken.text.trim().isEmpty) {
      setState(() => error = 'Venue tokenni kiriting.');
      return;
    }
    await _run(() async {
      final value = await service.connectVenue(venueToken.text);
      if (mounted) setState(() => snapshot = value);
    });
  }

  Future<void> _login() async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin.text)) {
      setState(() => error = 'PIN 4–6 ta raqamdan iborat bo\'lishi kerak.');
      return;
    }
    await _run(() => service.loginWithPin(pin.text));
  }

  Future<void> _setup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Birinchi xodimlarni yaratish'),
        content: const Text(
          'Administrator PIN: 0610\nKassir PIN: 0000\n\n'
          'Birinchi kirishdan keyin PIN-kodlarni sozlamalarda almashtiring.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Bekor qilish'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Yaratish'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _run(service.setupFirstStaff);
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (exception) {
      if (mounted) {
        setState(() => error = DeviceAccessService.readableError(exception));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _copyDeviceCode() {
    final code = snapshot?.deviceCode ?? '';
    if (code.isEmpty) return;
    Clipboard.setData(ClipboardData(text: code));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Qurilma kodi nusxalandi')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          const Expanded(flex: 5, child: _BrandPanel()),
          Expanded(
            flex: 6,
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(40),
                child: SizedBox(width: 480, child: _content(context)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content(BuildContext context) {
    if (snapshot == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const CircularProgressIndicator(),
          if (!busy) ...[
            Icon(Icons.cloud_off_rounded, size: 54, color: VColors.muted),
            const SizedBox(height: 20),
            Text(error ?? 'Ulanib bo\'lmadi', textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _initialize,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Qayta urinish'),
            ),
          ],
        ],
      );
    }

    return switch (snapshot!.phase) {
      DeviceAccessPhase.activation => _activationForm(context),
      DeviceAccessPhase.venue => _venueForm(context),
      DeviceAccessPhase.pin => _pinForm(context),
    };
  }

  Widget _activationForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          'Qurilmani faollashtirish',
          'Ushbu qurilma kodini owner-botga yuboring va bot bergan kalitlarni kiriting.',
        ),
        _DeviceCodeCard(code: snapshot!.deviceCode, onCopy: _copyDeviceCode),
        const SizedBox(height: 24),
        TextField(
          controller: activationCode,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(
            labelText: 'Faollashtirish kodi',
            prefixIcon: Icon(Icons.key_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: venueToken,
          decoration: const InputDecoration(
            labelText: 'Venue token',
            prefixIcon: Icon(Icons.storefront_rounded),
          ),
          onSubmitted: (_) => _activate(),
        ),
        _message(),
        const SizedBox(height: 22),
        _primaryButton('Faollashtirish va ulash', _activate),
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: busy ? null : _initialize,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('Holatni tekshirish'),
        ),
      ],
    );
  }

  Widget _venueForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          'Zavodga ulanish',
          'Owner-bot bergan 64 belgili venue tokenni bir marta kiriting.',
        ),
        _DeviceCodeCard(code: snapshot!.deviceCode, onCopy: _copyDeviceCode),
        const SizedBox(height: 24),
        TextField(
          controller: venueToken,
          decoration: const InputDecoration(
            labelText: 'Venue token',
            prefixIcon: Icon(Icons.storefront_rounded),
          ),
          onSubmitted: (_) => _connect(),
        ),
        _message(),
        const SizedBox(height: 22),
        _primaryButton('Ulash', _connect),
      ],
    );
  }

  Widget _pinForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          snapshot!.clubName ?? 'Xush kelibsiz',
          'Ishni davom ettirish uchun xodim PIN-kodini kiriting.',
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: VColors.greenSoft,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(Icons.verified_user_outlined, color: VColors.green),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                    'Qurilma ${snapshot!.deviceCode} • faollashtirilgan',
                    style: TextStyle(color: VColors.ink)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: pin,
          autofocus: true,
          obscureText: true,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          style: const TextStyle(fontSize: 26, letterSpacing: 12),
          decoration: const InputDecoration(
            labelText: 'Xodim PIN-kodi',
            prefixIcon: Icon(Icons.dialpad_rounded),
          ),
          onSubmitted: (_) => _login(),
        ),
        _message(),
        const SizedBox(height: 22),
        _primaryButton('Kirish', _login),
        if (!snapshot!.hasStaff) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: busy ? null : _setup,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: const Text('Birinchi administratorni yaratish'),
          ),
        ],
      ],
    );
  }

  Widget _heading(BuildContext context, String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(subtitle,
            style: TextStyle(color: VColors.muted, fontSize: 16)),
        const SizedBox(height: 28),
      ],
    );
  }

  Widget _message() {
    final text = error ?? snapshot?.message;
    if (text == null || text.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Text(
        text,
        style: TextStyle(color: error == null ? VColors.muted : VColors.red),
      ),
    );
  }

  Widget _primaryButton(String label, VoidCallback onPressed) {
    return FilledButton(
      onPressed: busy ? null : onPressed,
      child: busy
          ? const SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white),
            )
          : Text(label),
    );
  }
}

class _DeviceCodeCard extends StatelessWidget {
  const _DeviceCodeCard({required this.code, required this.onCopy});

  final String code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: VColors.field,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: VColors.line),
      ),
      child: Row(
        children: [
          Icon(Icons.desktop_windows_rounded, color: VColors.green),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Qurilma kodi',
                    style: TextStyle(color: VColors.muted)),
                const SizedBox(height: 3),
                SelectableText(
                  code,
                  style: TextStyle(
                    fontSize: 25,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 5,
                    color: VColors.ink,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Nusxalash',
            onPressed: onCopy,
            icon: const Icon(Icons.copy_rounded),
          ),
        ],
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      // Always dark with light text, regardless of the app's own
      // light/dark toggle — this is a fixed brand panel, not themed chrome.
      // (It used to read `VColors.ink`, which is near-white in dark mode —
      // white text on a near-white panel was invisible.)
      color: const Color(0xFF0D1526),
      padding: const EdgeInsets.all(64),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.sports_esports_rounded,
                  color: VColors.green, size: 32),
              const SizedBox(width: 12),
              Text(
                'Velora Club',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w900),
              ),
            ],
          ),
          const Spacer(),
          Text(
            'Klub boshqaruvi\nendi sodda.',
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Zal, sotuvlar, bronlar, mijozlar va hisobotlar — barchasi bitta oynada.',
            style: TextStyle(color: Color(0xFFAAB4C7), fontSize: 18),
          ),
          const Spacer(),
          Row(
            children: [
              Icon(Icons.wifi_rounded, color: VColors.green, size: 18),
              const SizedBox(width: 8),
              Text(
                'Supabase bilan himoyalangan ulanish',
                style: TextStyle(color: Color(0xFFAAB4C7)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
