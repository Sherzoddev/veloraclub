import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

  Future<DeviceAccessSnapshot> activateAndConnect({
    required String activationCode,
    required String venueToken,
  }) async {
    final preferences = await SharedPreferences.getInstance();
    final deviceCode = preferences.getString(deviceCodeKey) ?? '';
    if (deviceCode.isEmpty) throw StateError('DEVICE_CODE_MISSING');

    await _client.rpc('device_activate', params: {
      'p_device_code': deviceCode,
      'p_activation_code': activationCode.trim(),
    });
    await connectVenue(venueToken);
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
      'CODE_BOUND_ELSEWHERE': 'Bu kod boshqa qurilmaga biriktirilgan.',
      'CODE_NOT_PREPARED': 'Kod hali bot orqali tayyorlanmagan.',
      'UNKNOWN_TOKEN': 'Venue token noto\'g\'ri.',
      'TOKEN_REVOKED': 'Venue token bekor qilingan.',
      'CLUB_NOT_LICENSED': 'Zavod litsenziyasi faol emas.',
      'INVALID_PIN': 'PIN 4–6 ta raqamdan iborat bo\'lishi kerak.',
      'BAD_PIN': 'PIN noto\'g\'ri.',
      'LOCKED': 'Kirish vaqtincha bloklangan. Keyinroq urinib ko\'ring.',
      'ALREADY_SET_UP': 'Xodimlar allaqachon yaratilgan.',
      'NOT_ACTIVATED': 'Qurilma hali faollashtirilmagan.',
      'VENUE_TOKEN_REQUIRED': 'Venue tokenni kiriting.',
      'SESSION_NOT_CREATED': 'Xavfsiz sessiya yaratilmadi.',
    };
    for (final entry in known.entries) {
      if (raw.contains(entry.key)) return entry.value;
    }
    return 'Ulanishda xatolik. Internetni tekshirib, qayta urinib ko\'ring.';
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
    switch (reason) {
      case 'NOT_ACTIVATED':
        return 'Qurilmani owner-bot orqali faollashtiring.';
      case 'NO_LICENSE':
        return 'Faol litsenziya topilmadi.';
      case 'EXPIRED':
        return 'Litsenziya muddati tugagan.';
      case 'VENUE_REVOKED':
        return 'Venue token bekor qilingan.';
      case 'UNKNOWN_VENUE':
        return 'Saqlangan venue token yaroqsiz.';
      default:
        return null;
    }
  }

  static String _randomId(int length) {
    const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final random = Random.secure();
    return List.generate(
        length, (_) => alphabet[random.nextInt(alphabet.length)]).join();
  }
}
