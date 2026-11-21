import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:velora_club/src/services/serial_queue.dart';

void main() {
  SerialQueue quick() => SerialQueue(
      timeout: const Duration(milliseconds: 80),
      attempts: 2,
      pause: const Duration(milliseconds: 5));

  test('a command that works goes through at once', () async {
    var calls = 0;
    await quick().send(() async => calls++);
    expect(calls, 1);
  });

  test('a command that fails once is tried again', () async {
    var calls = 0;
    await quick().send(() async {
      calls++;
      if (calls == 1) throw StateError('port busy');
    });
    expect(calls, 2);
  });

  test('a stuck port is given up after the time limit, not waited for',
      () async {
    final watch = Stopwatch()..start();
    await expectLater(
      quick().send(() => Completer<void>().future), // never ends
      throwsA(isA<TimeoutException>()),
    );
    // two tries of 80 ms and a pause: well under a second, not "forever"
    expect(watch.elapsedMilliseconds, lessThan(1000));
  });

  test('the last error is reported when every try fails', () async {
    await expectLater(
      quick().send(() async => throw StateError('no such port')),
      throwsA(isA<StateError>()),
    );
  });

  test('commands go one after another, never at the same time', () async {
    final q = quick();
    final log = <String>[];
    var running = 0;
    var overlapped = false;

    Future<void> command(String name) => q.send(() async {
          running++;
          if (running > 1) overlapped = true;
          log.add('start $name');
          await Future<void>.delayed(const Duration(milliseconds: 20));
          log.add('end $name');
          running--;
        });

    await Future.wait([command('a'), command('b'), command('c')]);
    expect(overlapped, isFalse);
    expect(log, [
      'start a',
      'end a',
      'start b',
      'end b',
      'start c',
      'end c',
    ]);
  });

  test('one failed command does not block the ones after it', () async {
    final q = quick();
    final failing = q.send(() async => throw StateError('x'));
    var ok = false;
    final next = q.send(() async => ok = true);
    await expectLater(failing, throwsA(isA<StateError>()));
    await next;
    expect(ok, isTrue);
  });
}
