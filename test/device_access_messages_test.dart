import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/services/device_access_service.dart';

void main() {
  test('activation errors read as plain club/code words, never "zavod"', () {
    String msg(String reason) => DeviceAccessService.readableError(StateError(reason));

    expect(msg('CLUB_NOT_LICENSED'), contains('faollashtirish kodini'));
    expect(msg('CODE_ALREADY_USED'), 'Bu kod boshqa klubda ishlatilgan.');
    expect(msg('CODE_BOUND_ELSEWHERE'), 'Bu kod boshqa kompyuter uchun berilgan.');
    expect(msg('UNKNOWN_CODE'), "Faollashtirish kodi noto'g'ri.");
    expect(msg('UNKNOWN_TOKEN'), "Klub tokeni noto'g'ri.");
    expect(msg('LOCKED'), startsWith("Juda ko'p"));
    for (final reason in ['CLUB_NOT_LICENSED', 'UNKNOWN_TOKEN', 'TOKEN_REVOKED', 'VENUE_TOKEN_REQUIRED']) {
      expect(msg(reason).toLowerCase(), isNot(contains('zavod')));
      expect(msg(reason).toLowerCase(), isNot(contains('venue')));
    }
  });
}
