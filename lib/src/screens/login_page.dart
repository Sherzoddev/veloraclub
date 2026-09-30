import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../i18n.dart';
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
  // PIN screen -> "connect to another club": show the connect form again.
  bool switching = false;

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

  /// Activation code + club token -> straight in. The code is optional only
  /// when this computer is already activated and the token's club already
  /// has a license (a second till of the same club).
  Future<void> _connectClub() async {
    final code = activationCode.text.trim();
    final token = venueToken.text.trim();
    final needsCode = snapshot?.phase == DeviceAccessPhase.activation;
    if (token.isEmpty || (needsCode && code.isEmpty)) {
      setState(() => error = tr(needsCode
          ? 'Faollashtirish kodi va klub tokenini kiriting.'
          : 'Klub tokenini kiriting.'));
      return;
    }
    await _run(() async {
      final value = code.isNotEmpty
          ? await service.activateAndConnect(
              activationCode: code, venueToken: token)
          : await service.connectVenue(token);
      if (mounted) {
        setState(() {
          snapshot = value;
          switching = false;
          activationCode.clear();
          venueToken.clear();
        });
      }
    });
  }

  Future<void> _login() async {
    if (!RegExp(r'^\d{4,6}$').hasMatch(pin.text)) {
      setState(() => error = tr('PIN 4–6 ta raqamdan iborat bo\'lishi kerak.'));
      return;
    }
    await _run(() => service.loginWithPin(pin.text));
  }

  Future<void> _setup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(tr('Birinchi xodimlarni yaratish')),
        content: Text(
          'Administrator PIN: 0610\n${tr('Kassir')} PIN: 0000\n\n'
          '${tr('Birinchi kirishdan keyin PIN-kodlarni sozlamalarda almashtiring.')}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Bekor qilish')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('Yaratish')),
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
      SnackBar(content: Text(tr('Qurilma kodi nusxalandi'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: LocaleController.instance,
      builder: (context, _) => Scaffold(
        body: SafeArea(
          child: LayoutBuilder(builder: (context, constraints) {
            // Phones: just the form; the brand panel needs a wide screen.
            final narrow = constraints.maxWidth < 820;
            final form = Stack(
              children: [
                Center(
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(narrow ? 20 : 40,
                        narrow ? 64 : 40, narrow ? 20 : 40, narrow ? 20 : 40),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _content(context),
                    ),
                  ),
                ),
                Positioned(
                    top: narrow ? 12 : 20,
                    right: narrow ? 16 : 24,
                    child: const _LangSwitch()),
              ],
            );
            if (narrow) return form;
            return Row(
              children: [
                const Expanded(flex: 5, child: _BrandPanel()),
                Expanded(flex: 6, child: form),
              ],
            );
          }),
        ),
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
            Text(error ?? tr('Ulanib bo\'lmadi'), textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _initialize,
              icon: const Icon(Icons.refresh_rounded),
              label: Text(tr('Qayta urinish')),
            ),
          ],
        ],
      );
    }

    if (switching || snapshot!.phase != DeviceAccessPhase.pin) {
      return _connectForm(context);
    }
    return _pinForm(context);
  }

  Widget _connectForm(BuildContext context) {
    final needsCode = snapshot!.phase == DeviceAccessPhase.activation;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          tr(needsCode ? 'Dasturni faollashtirish' : 'Klubga ulash'),
          tr(needsCode
              ? 'Faollashtirish kodi va klub tokenini kiriting — shu zahoti kirasiz.'
              : 'Klub tokenini kiriting. Klub hali faollashtirilmagan bo\'lsa, faollashtirish kodini ham kiriting.'),
        ),
        _DeviceCodeCard(code: snapshot!.deviceCode, onCopy: _copyDeviceCode),
        const SizedBox(height: 24),
        TextField(
          controller: activationCode,
          textCapitalization: TextCapitalization.characters,
          decoration: InputDecoration(
            labelText: tr('Faollashtirish kodi'),
            helperText:
                needsCode ? null : tr('Ixtiyoriy — faqat yangi klub uchun'),
            prefixIcon: const Icon(Icons.key_rounded),
          ),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: venueToken,
          decoration: InputDecoration(
            labelText: tr('Klub tokeni'),
            prefixIcon: const Icon(Icons.storefront_rounded),
          ),
          onSubmitted: (_) => _connectClub(),
        ),
        _message(),
        const SizedBox(height: 22),
        _primaryButton(tr('Kirish'), _connectClub),
        const SizedBox(height: 10),
        if (switching)
          TextButton.icon(
            onPressed: busy
                ? null
                : () => setState(() {
                      switching = false;
                      error = null;
                    }),
            icon: const Icon(Icons.arrow_back_rounded),
            label: Text(tr('Orqaga')),
          )
        else
          TextButton.icon(
            onPressed: busy ? null : _initialize,
            icon: const Icon(Icons.refresh_rounded),
            label: Text(tr('Holatni tekshirish')),
          ),
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
          snapshot!.clubName ?? tr('Xush kelibsiz'),
          tr('Ishni davom ettirish uchun xodim PIN-kodini kiriting.'),
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
                    '${tr('Kompyuter')} ${snapshot!.deviceCode} • ${tr('faollashtirilgan')}',
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
          decoration: InputDecoration(
            labelText: tr('Xodim PIN-kodi'),
            prefixIcon: const Icon(Icons.dialpad_rounded),
          ),
          onSubmitted: (_) => _login(),
        ),
        _message(),
        const SizedBox(height: 22),
        _primaryButton(tr('Kirish'), _login),
        if (!snapshot!.hasStaff) ...[
          const SizedBox(height: 14),
          OutlinedButton.icon(
            onPressed: busy ? null : _setup,
            icon: const Icon(Icons.person_add_alt_1_rounded),
            label: Text(tr('Birinchi administratorni yaratish')),
          ),
        ],
        const SizedBox(height: 10),
        TextButton.icon(
          onPressed: busy
              ? null
              : () => setState(() {
                    switching = true;
                    error = null;
                  }),
          icon: const Icon(Icons.swap_horiz_rounded),
          label: Text(tr('Boshqa klubga ulash')),
        ),
      ],
    );
  }

  Widget _heading(BuildContext context, String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(subtitle, style: TextStyle(color: VColors.muted, fontSize: 16)),
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
                Text(tr('Kompyuter kodi'),
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
            tooltip: tr('Nusxalash'),
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
            tr('Klub boshqaruvi\nendi sodda.'),
            style: Theme.of(context).textTheme.displayMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  height: 1.05,
                ),
          ),
          const SizedBox(height: 20),
          Text(
            tr('Zal, sotuvlar, bronlar, mijozlar va hisobotlar — barchasi bitta oynada.'),
            style: const TextStyle(color: Color(0xFFAAB4C7), fontSize: 18),
          ),
          const Spacer(),
          Row(
            children: [
              Icon(Icons.wifi_rounded, color: VColors.green, size: 18),
              const SizedBox(width: 8),
              Text(
                tr('Himoyalangan ulanish'),
                style: TextStyle(color: Color(0xFFAAB4C7)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// UZ / RU switch for the login screen -- the owner may not read Uzbek.
class _LangSwitch extends StatelessWidget {
  const _LangSwitch();

  @override
  Widget build(BuildContext context) {
    final ru = LocaleController.instance.isRu;
    Widget chip(String label, bool active) => GestureDetector(
          onTap: active ? null : LocaleController.instance.toggle,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: active ? VColors.green : VColors.field,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Text(label,
                style: TextStyle(
                    fontWeight: FontWeight.w800,
                    color: active ? Colors.white : VColors.muted)),
          ),
        );
    return Row(mainAxisSize: MainAxisSize.min, children: [
      chip('UZ', !ru),
      const SizedBox(width: 6),
      chip('RU', ru),
    ]);
  }
}
