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
  static Future<void> assertEnumerationWorks() async {
    const script =
        'tell application "System Events"\n'
        '  set total to 0\n'
        '  repeat with p in (processes whose background only is false)\n'
        '    set total to total + (count of windows of p)\n'
        '  end repeat\n'
        '  return total\n'
        'end tell';
    final result = await Process.run('osascript', ['-e', script]).timeout(
      const Duration(seconds: 20),
      onTimeout: () => ProcessResult(0, 1, '', 'System Events did not respond'),
    );
    final total = result.exitCode == 0
        ? int.tryParse(result.stdout.toString().trim()) ?? 0
        : 0;
    if (total > 0) return;

    stderr.writeln(
      'FAIL: System Events reports no windows for any process, so '
      'it cannot answer for ours either.',
    );
    if (result.exitCode != 0) {
      stderr.writeln('osascript: ${result.stderr.toString().trim()}');
    }
    stderr.writeln(
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
