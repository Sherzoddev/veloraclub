import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../i18n.dart';

enum DeviceAccessPhase { activation, venue, pin }

class DeviceAccessSnapshot {
  const DeviceAccessSnapshot({
    required this.phase,
    required this.deviceCode,
    this.clubName,
    this.expiresAt,
    this.hasStaff = false,
    this.message,
  });

  final DeviceAccessPhase phase;
  final String deviceCode;
  final String? clubName;
  final DateTime? expiresAt;
  final bool hasStaff;
  final String? message;
}

class SetupPins {
  const SetupPins({required this.adminPin, required this.cashierPin});

  final String adminPin;
  final String cashierPin;
}

class DeviceAccessService {
  DeviceAccessService({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  static const deviceCodeKey = 'velora_device_code';
  static const hardwareIdKey = 'velora_hardware_id';
  static const venueTokenKey = 'velora_venue_token';

  final SupabaseClient _client;

  Future<DeviceAccessSnapshot> initialize() async {
    final preferences = await SharedPreferences.getInstance();
    var hardwareId = preferences.getString(hardwareIdKey);
    if (hardwareId == null || hardwareId.isEmpty) {
      hardwareId = _randomId(32);
      await preferences.setString(hardwareIdKey, hardwareId);
    }

    final storedCode = preferences.getString(deviceCodeKey) ?? '';
    final result = _jsonMap(await _client.rpc('device_check_in', params: {
      'p_device_code': storedCode,
      'p_name': 'Velora Club Windows',
      'p_platform': 'windows',
      'p_hardware_id': hardwareId,
    }));

    final deviceCode = (result['device_code'] ?? storedCode).toString();
    if (deviceCode.isNotEmpty) {
      await preferences.setString(deviceCodeKey, deviceCode);
    }

    if (result['ok'] != true) {
      final reason = result['reason']?.toString();
      return DeviceAccessSnapshot(
        phase: DeviceAccessPhase.activation,
        deviceCode: deviceCode,
        expiresAt: _date(result['expires_at']),
        message: _reasonText(reason),
      );
    }

    final venueToken = preferences.getString(venueTokenKey)?.trim() ?? '';
    if (venueToken.isEmpty) {
      return DeviceAccessSnapshot(
        phase: DeviceAccessPhase.venue,
        deviceCode: deviceCode,
        clubName: result['club_name']?.toString(),
        expiresAt: _date(result['expires_at']),
        hasStaff: result['has_staff'] == true,
      );
    }

    applyVenueToken(_client, venueToken);
    final license = _jsonMap(await _client.rpc(
      'license_status',
      params: {'p_venue_token': venueToken},
    ));
    if (license['ok'] != true) {
      return DeviceAccessSnapshot(
        phase: license['reason'] == 'EXPIRED'
            ? DeviceAccessPhase.activation
            : DeviceAccessPhase.venue,
        deviceCode: deviceCode,
        clubName: license['club_name']?.toString(),
        expiresAt: _date(license['expires_at']),
        hasStaff: result['has_staff'] == true,
        message: _reasonText(license['reason']?.toString()),
      );
    }

    await _client.rpc('device_join_club', params: {
      'p_device_code': deviceCode,
      'p_venue_token': venueToken,
    });
    return DeviceAccessSnapshot(
      phase: DeviceAccessPhase.pin,
      deviceCode: deviceCode,
      clubName: (license['club_name'] ?? result['club_name'])?.toString(),
      expiresAt: _date(license['expires_at'] ?? result['expires_at']),
      hasStaff: result['has_staff'] == true,
    );
  }

  /// Activation code + venue token in one step. The code is the vendor's
  /// permission to run the program on this computer; the token says which
  /// club it is -- the code gets activated for that club on first use, no
  /// matter which club the bot prepared it for.
  Future<DeviceAccessSnapshot> activateAndConnect({
    required String activationCode,
    required String venueToken,
  }) async {
    final token = venueToken.replaceAll(RegExp(r'\s'), '');
    if (token.isEmpty) throw StateError('VENUE_TOKEN_REQUIRED');
    final preferences = await SharedPreferences.getInstance();
    final deviceCode = preferences.getString(deviceCodeKey) ?? '';
    if (deviceCode.isEmpty) throw StateError('DEVICE_CODE_MISSING');

    final result = _jsonMap(await _client.rpc('device_activate_venue', params: {
      'p_device_code': deviceCode,
      'p_activation_code': activationCode.trim(),
      'p_venue_token': token,
    }));
    if (result['ok'] != true) {
      throw StateError(result['reason']?.toString() ?? 'SERVER_ERROR');
    }
    await preferences.setString(venueTokenKey, token);
    applyVenueToken(_client, token);
    return initialize();
  }

  Future<DeviceAccessSnapshot> connectVenue(String venueToken) async {
    final token = venueToken.replaceAll(RegExp(r'\s'), '');
    if (token.isEmpty) throw StateError('VENUE_TOKEN_REQUIRED');

    final preferences = await SharedPreferences.getInstance();
    final deviceCode = preferences.getString(deviceCodeKey) ?? '';
    if (deviceCode.isEmpty) throw StateError('DEVICE_CODE_MISSING');

    await _client.rpc('device_join_club', params: {
      'p_device_code': deviceCode,
      'p_venue_token': token,
    });
    await preferences.setString(venueTokenKey, token);
    applyVenueToken(_client, token);
    return initialize();
  }

  Future<void> loginWithPin(String pin) async {
    final preferences = await SharedPreferences.getInstance();
    final deviceCode = preferences.getString(deviceCodeKey) ?? '';
    final response = await _client.functions.invoke(
      'pin-login',
      body: {'device_code': deviceCode, 'pin': pin, 'action': 'login'},
    );
    final data = _jsonMap(response.data);
    _throwFunctionError(response.status, data);
    await _verifyTokenHash(data);
  }

  Future<SetupPins> setupFirstStaff() async {
    final preferences = await SharedPreferences.getInstance();
    final deviceCode = preferences.getString(deviceCodeKey) ?? '';
    final response = await _client.functions.invoke(
      'pin-login',
      body: {
        'device_code': deviceCode,
        'action': 'setup',
        'full_name': 'Администратор',
      },
    );
    final data = _jsonMap(response.data);
    _throwFunctionError(response.status, data);
    await _verifyTokenHash(data);
    return SetupPins(
      adminPin: data['admin_pin']?.toString() ?? '0610',
      cashierPin: data['cashier_pin']?.toString() ?? '0000',
    );
  }

  Future<void> _verifyTokenHash(Map<String, dynamic> data) async {
    final tokenHash = data['token_hash']?.toString();
    if (tokenHash == null || tokenHash.isEmpty) {
      throw StateError('SESSION_NOT_CREATED');
    }
    final response = await _client.auth.verifyOTP(
      tokenHash: tokenHash,
      type: OtpType.email,
    );
    if (response.session == null) throw StateError('SESSION_NOT_CREATED');
  }

  static void applyVenueToken(SupabaseClient client, String? venueToken) {
    final headers = Map<String, String>.from(client.headers);
    if (venueToken == null || venueToken.isEmpty) {
      headers.remove('x-venue-token');
    } else {
      headers['x-venue-token'] = venueToken;
    }
    client.headers = headers;
  }

  static String readableError(Object error) {
    final raw = error.toString();
    const known = <String, String>{
      'UNKNOWN_DEVICE': 'Qurilma topilmadi. Ilovani qayta ishga tushiring.',
      'UNKNOWN_CODE': 'Faollashtirish kodi noto\'g\'ri.',
      'CODE_REVOKED': 'Faollashtirish kodi bekor qilingan.',
      'CODE_BOUND_ELSEWHERE': 'Bu kod boshqa kompyuter uchun berilgan.',
      'CODE_ALREADY_USED': 'Bu kod boshqa klubda ishlatilgan.',
      'CODE_NOT_PREPARED': 'Faollashtirish kodi va klub tokenini birga kiriting.',
      'UNKNOWN_TOKEN': 'Klub tokeni noto\'g\'ri.',
      'TOKEN_REVOKED': 'Klub tokeni bekor qilingan.',
      'CLUB_NOT_LICENSED': 'Bu klub hali faollashtirilmagan — faollashtirish kodini ham kiriting.',
      'EXPIRED': 'Litsenziya muddati tugagan.',
      'LOCKED': 'Juda ko\'p noto\'g\'ri urinish. Keyinroq qayta urinib ko\'ring.',
      'INVALID_PIN': 'PIN 4–6 ta raqamdan iborat bo\'lishi kerak.',
      'BAD_PIN': 'PIN noto\'g\'ri.',
      'ALREADY_SET_UP': 'Xodimlar allaqachon yaratilgan.',
      'NOT_ACTIVATED': 'Kompyuter hali faollashtirilmagan.',
      'VENUE_TOKEN_REQUIRED': 'Klub tokenini kiriting.',
      'SESSION_NOT_CREATED': 'Xavfsiz sessiya yaratilmadi.',
    };
    for (final entry in known.entries) {
      if (raw.contains(entry.key)) return tr(entry.value);
    }
    return tr('Ulanishda xatolik. Internetni tekshirib, qayta urinib ko\'ring.');
  }

  static Map<String, dynamic> _jsonMap(dynamic value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.map((key, item) => MapEntry('$key', item));
    return <String, dynamic>{};
  }

  static void _throwFunctionError(int status, Map<String, dynamic> data) {
    if (status >= 200 && status < 300 && data['ok'] == true) return;
    throw StateError(data['error']?.toString() ?? 'SERVER_ERROR');
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    return DateTime.tryParse(value.toString())?.toLocal();
  }

  static String? _reasonText(String? reason) {
    final text = switch (reason) {
      'NOT_ACTIVATED' => 'Faollashtirish kodi va klub tokenini kiriting.',
      'NO_LICENSE' => 'Bu klub hali faollashtirilmagan — faollashtirish kodini kiriting.',
      'EXPIRED' => 'Litsenziya muddati tugagan.',
      'VENUE_REVOKED' => 'Klub tokeni bekor qilingan.',
      'UNKNOWN_VENUE' => 'Saqlangan klub tokeni yaroqsiz.',
      _ => null,
    };
    return text == null ? null : tr(text);
  }

  static String _randomId(int length) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(
        length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }
}
