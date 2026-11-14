/// Asking the window server what windows a launched macOS app has.
library;

import 'dart:async';
import 'dart:io';

import 'app_process.dart';
import 'macos_gui_session.dart';

/// The windows of an [AppProcess], through System Events.
///
/// It needs a live GUI session (unlocked screen, awake display, which
/// [GuiSession.hold] provides for the latter) and an accessibility grant for
/// the test runner. When System Events cannot answer, that is the harness
/// failing and not the app, so these methods say so, name which of those
/// is missing, and exit 1 rather than report no windows.
class AppWindows {
  /// The windows of [app], found by its pid.
  AppWindows(this.app);

  /// The app asked about.
  final AppProcess app;

  /// Counts the windows of every foreground process, one process at a time.
  ///
  /// Each process is read inside its own `try`: System Events resolves
  /// `processes whose …` against a process list that other work changes while
  /// it is read. On a busy Mac (concurrent builds, other test runs) one process
  /// exiting mid-read fails the whole expression with `-1719` ("Invalid
  /// index"), and the same expression failed 12 times out of 12 in a row on
  /// one measured Mac. Reading per process turns that into a process counted
  /// as unreadable. The answer is `windows,processes,unreadable`.
  static const _enumerationScript = '''
tell application "System Events"
  set total to 0
  set seen to 0
  set unreadable to 0
  repeat with p in (every application process)
    try
      if background only of p is false then
        set total to total + (count of windows of p)
        set seen to seen + 1
      end if
    on error
      set unreadable to unreadable + 1
    end try
  end repeat
  return (total as text) & "," & (seen as text) & "," & (unreadable as text)
end tell''';

  /// What is wrong with an enumeration that [exitCode], [stdout] and [stderr]
  /// describe, or null if it found windows.
  ///
  /// A System Events that errored and one that answered "none" are different
  /// failures with different fixes, and reading both as "no windows" sent a
  /// healthy session to the wrong diagnosis. Only an answer of zero windows
  /// from processes it read is "no windows".
  static String? assessEnumeration({
    required int exitCode,
    required String stdout,
    required String stderr,
  }) {
    if (exitCode != 0) {
      return 'System Events did not answer the window enumeration: '
          '${stderr.trim()}';
    }
    final parts = stdout.trim().split(',').map(int.tryParse).toList();
    if (parts.length != 3 || parts.contains(null)) {
      return 'System Events answered the window enumeration with something '
          'that is not a reading: "${stdout.trim()}"';
    }
    final [windows!, read!, unreadable!] = parts;
    if (windows > 0) return null;
    if (read == 0) {
      return unreadable == 0
          ? 'System Events lists no foreground processes at all'
          : 'System Events could not read any process ($unreadable of them '
                'failed)';
    }
    return unreadable == 0
        ? 'System Events reports no windows for any of $read processes'
        : 'System Events reports no windows for the $read processes it could '
              'read, and could not read $unreadable others';
  }

  /// Fails the run if System Events cannot enumerate windows at all.
  ///
  /// It reports success and a count of zero in two very different situations:
  /// the process genuinely has no window, and the accessibility path is
  /// wedged, after which *every* process on the machine reports zero, Finder
  /// included. Without this probe the second case is indistinguishable from a
  /// Flutter app that came up blank, and the test spends 30 seconds before
  /// blaming the app. A desktop with a window server running always has some
  /// windowed process, so a total of zero is the harness failing, not an
  /// answer.
  ///
  /// An enumeration that errors is reported as that ([assessEnumeration]),
  /// not as zero windows.
  static Future<void> assertEnumerationWorks() async {
    // Reading each process takes 7 to 15 seconds on a Mac running a dozen
    // builds, so the bound is a hang's, not a typical wait's.
    const bound = Duration(seconds: 60);
    final result = await Process.run('osascript', ['-e', _enumerationScript])
        .timeout(
          bound,
          onTimeout: () => ProcessResult(
            0,
            1,
            '',
            'System Events did not respond in ${bound.inSeconds}s',
          ),
        );
    final problem = assessEnumeration(
      exitCode: result.exitCode,
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
    if (problem == null) return;

    stderr
      ..writeln('FAIL: $problem, so it cannot answer for our app either.')
      ..writeln(
        'This is a harness failure, not an app failure. '
        '${await GuiSession.diagnosis()}',
      );
    exit(1);
  }

  /// Windows belonging to the app, or 0 when it has none.
  ///
  /// A nonzero exit from osascript is not "no windows": it is "the question
  /// was not answered", most often because the accessibility grant for window
  /// enumeration is missing or System Events is wedged. Reporting 0 there
  /// turns a broken harness into a 30-second wait ending in a verdict about
  /// the app, so the error is surfaced instead.
  Future<int> count() async {
    final script =
        'tell application "System Events" to get (count of windows '
        'of (first process whose unix id is ${app.pid}))';
    final result = await Process.run('osascript', ['-e', script]);
    if (result.exitCode != 0) {
      final message = result.stderr.toString().trim();
      // The process may not have registered with the window server yet; that
      // shows up as "can't get process" and is a legitimate not-yet.
      if (message.contains('-1719') || message.contains('Can’t get')) return 0;
      stderr
        ..writeln('FAIL: cannot query windows via System Events: $message')
        ..writeln(
          'This is a harness failure, not an app failure. '
          '${await GuiSession.diagnosis()}',
        );
      exit(1);
    }
    return int.tryParse(result.stdout.toString().trim()) ?? 0;
  }

  /// Waits up to [timeout] for the app to show a window. False if none
  /// appears, after printing what the session looked like when it gave up:
  /// the session going dark during the wait (the screen locking, the display
  /// idling out) looks the same as an app that never drew.
  ///
  /// Exits 1 if the app exits first: a crash ends before any window can
  /// appear, and that is reported at once instead of after the wait.
  Future<bool> waitForWindow(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (app.exited) {
        stderr.writeln(
          'FAIL: process ${app.pid} exited with code ${app.exitCode} before '
          'showing a window',
        );
        exit(1);
      }
      if (await count() > 0) return true;
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    final state = await GuiSession.probe();
    final blocker = GuiSession.diagnose(state);
    stderr.writeln(
      blocker == GuiBlocker.unknown
          ? 'The desktop session was live ($state), so the app itself drew '
                'no window.'
          : 'The window may be missing because of the session, not the app. '
                '${GuiSession.explain(blocker)} (Read: $state.)',
    );
    return false;
  }

  /// The size of the app's first window, as (width, height), each 0 if System
  /// Events gave none.
  Future<(int, int)> size() async {
    final script =
        'tell application "System Events" to tell (first '
        'process whose unix id is ${app.pid}) to get size of window 1';
    final result = await Process.run('osascript', ['-e', script]);
    final parts = result.stdout
        .toString()
        .trim()
        .split(',')
        .map((s) => int.tryParse(s.trim()) ?? 0)
        .toList();
    return (
      parts.isNotEmpty ? parts[0] : 0,
      parts.length > 1 ? parts[1] : 0,
    );
  }
}
