// Safe delivery of a short command to a COM port (the USB relay that switches
// a table's light).
//
// Opening and writing a COM port are blocking calls. Done on the window's own
// thread, a USB-serial adapter that "sticks" (they do) froze the whole program
// for many seconds: the light command never left, and because the screen is
// refreshed after it, the table kept looking open — so the cashier pressed
// "finish" again and got "already finished". Here a command
//
//  * runs through [run] (an isolate in the program), never on the window thread,
//  * gets a time limit and one more try,
//  * waits for the commands before it (two commands never fight for one port).
import 'dart:async';

typedef SerialAttempt = Future<void> Function();

class SerialQueue {
  SerialQueue({
    this.timeout = const Duration(seconds: 4),
    this.attempts = 2,
    this.pause = const Duration(milliseconds: 300),
  });

  final Duration timeout;
  final int attempts;
  final Duration pause;

  Future<void> _tail = Future<void>.value();

  /// Runs [attempt] (one try of the write) until it works or the tries are
  /// used up. Throws the last error (a time-out included).
  Future<void> send(SerialAttempt attempt) {
    final done = Completer<void>();
    _tail = _tail.then((_) async {
      Object? last;
      for (var i = 0; i < attempts; i++) {
        try {
          await attempt().timeout(timeout);
          done.complete();
          return;
        } catch (e) {
          last = e;
          if (i + 1 < attempts) await Future<void>.delayed(pause);
        }
      }
      done.completeError(last ?? StateError('serial write failed'));
    });
    // The queue goes on whatever happened to one command.
    _tail = _tail.catchError((_) {});
    return done.future;
  }
}
