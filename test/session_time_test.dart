import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/screens/club_page.dart';

void main() {
  // A table started for 30 000 at 60 000/h: the light goes off at 30 min and
  // the cashier closes it 3 min 23 s later. The card must stop at 30:00 and
  // 30 000, the same as the server's receipt, not keep counting to 34 000.
  final started = DateTime.utc(2026, 9, 29, 8, 33, 25);
  final session = {
    'status': 'ACTIVE',
    'started_at': started.toIso8601String(),
    'planned_end_at':
        started.add(const Duration(minutes: 30)).toIso8601String(),
    'paused_seconds': 0,
    'prepaid_amount': 30000,
  };
  final late = started.add(const Duration(minutes: 33, seconds: 23));

  test('time stops at the planned end', () {
    expect(sessionPlayedSeconds(session, late), 1800);
    expect(sessionTimeCharge(session, 60000, late), 30000);
  });

  test('before the end it counts as usual', () {
    final at = started.add(const Duration(minutes: 10));
    expect(sessionPlayedSeconds(session, at), 600);
    expect(sessionTimeCharge(session, 60000, at), 10000);
  });

  test('the charge never goes above the sum paid for', () {
    // 35 500 at 60 000/h is 35.5 min; rounding must not add to it.
    final s = {
      ...session,
      'prepaid_amount': 35500,
      'planned_end_at':
          started.add(const Duration(seconds: 2130)).toIso8601String()
    };
    expect(sessionTimeCharge(s, 60000, late.add(const Duration(minutes: 5))),
        35500);
  });

  test('a table without a sum keeps counting', () {
    final open = {...session}
      ..remove('planned_end_at')
      ..remove('prepaid_amount');
    expect(sessionPlayedSeconds(open, late), 2003);
    expect(sessionTimeCharge(open, 60000, late), 33383);
  });

  test('a pause is not counted', () {
    final paused = {
      ...session,
      'status': 'PAUSED',
      'pause_started_at':
          started.add(const Duration(minutes: 10)).toIso8601String()
    };
    expect(sessionPlayedSeconds(paused, late), 600);
  });

  timeUpTests();
}

void timeUpTests() {
  final started = DateTime.utc(2026, 10, 2, 9, 0, 0);
  final end = started.add(const Duration(minutes: 30));
  Map<String, dynamic> paused(DateTime at) => {
        'status': 'PAUSED',
        'started_at': started.toIso8601String(),
        'planned_end_at': end.toIso8601String(),
        'pause_started_at': at.toIso8601String(),
      };

  test('a table paused right at the planned end is waiting for the cashier',
      () {
    expect(sessionTimeUpPaused(paused(end.add(const Duration(seconds: 2)))),
        isTrue);
    expect(sessionTimeUpPaused(paused(end.add(const Duration(minutes: 20)))),
        isTrue);
  });

  test('a pause pressed by hand before the end is an ordinary pause', () {
    expect(
        sessionTimeUpPaused(paused(end.subtract(const Duration(minutes: 5)))),
        isFalse);
  });

  test('a running table is never "time up paused"', () {
    expect(
        sessionTimeUpPaused({
          'status': 'ACTIVE',
          'planned_end_at': end.toIso8601String(),
        }),
        isFalse);
  });
}
