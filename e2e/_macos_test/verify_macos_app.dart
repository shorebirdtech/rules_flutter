/// Verifies a Flutter macOS .app bundle launches and creates a window.
///
/// Usage: dart run verify_macos_app.dart <path/to/App.app> [expected_title]
///
/// Verification:
/// 0. Declares the user active (`caffeinate -d -u`), which wakes a sleeping
///    display and keeps it on: System Events reports no windows while the
///    display is asleep
/// 1. Launches the app binary directly to capture stdout/stderr
/// 2. Polls for window existence (up to 30s); if none appears, says whether
///    the screen was locked, the display asleep or Accessibility untrusted
/// 3. Verifies window has non-zero size (proves Flutter rendered a frame)
/// 4. Checks window title bar text matches expected title (if provided)
/// 5. Attempts screenshot via `screencapture` (best-effort, may fail in CI)
/// 6. Quits the app
///
/// Pass criteria: window appears with non-zero dimensions.
///
/// Note: Flutter renders to a Metal surface — its widget content does NOT
/// appear in the macOS accessibility tree. Window existence + non-zero size
/// is the strongest signal available without UI automation frameworks.
///
/// This file stands alone: `tools/vm` copies this directory to bare machines,
/// so it cannot import `tools/e2e_testing`. Its session hold and diagnosis
/// are a copy of `macos_gui_session.dart` there; keep the two in step.
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run verify_macos_app.dart <app_path> [expected_title]',
    );
    exit(1);
  }

  final appPath = args[0];
  final caffeinate = await Process.start('caffeinate', [
    '-d',
    '-u',
    '-w',
    '$pid',
  ]);
  await _waitForDisplay();
  final expectedTitle = args.length > 1 ? args[1] : null;

  if (!Directory(appPath).existsSync()) {
    stderr.writeln('App bundle not found: $appPath');
    exit(1);
  }

  // Extract process name from .app bundle (e.g. "app.app" → "app").
  final bundleName = Uri.parse(
    appPath,
  ).pathSegments.last.replaceAll('.app', '');

  // Find the executable binary inside the bundle.
  final binaryPath = '$appPath/Contents/MacOS/$bundleName';

  // Launch the app binary directly to capture stdout/stderr.
  print('Launching $bundleName from $appPath ...');
  if (!File(binaryPath).existsSync()) {
    stderr.writeln('App binary not found at $binaryPath');
    exit(1);
  }
  print('Launching binary directly: $binaryPath');
  final appProcess = await Process.start(binaryPath, []);

  // Collect process output in background.
  final stdoutLines = <String>[];
  final stderrLines = <String>[];
  appProcess.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stdoutLines.add(line);
        print('[stdout] $line');
      });
  appProcess.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        stderrLines.add(line);
        print('[stderr] $line');
      });

  // Poll for the window to appear.
  print('Waiting for window (up to 30s) ...');
  final windowFound = await _pollFor(
    const Duration(seconds: 30),
    () => _hasWindow(bundleName),
  );

  if (!windowFound) {
    stderr.writeln('FAIL: No window found for $bundleName after 30s');
    stderr.writeln(await _diagnoseSession());
    appProcess.kill();
    caffeinate.kill();
    _printStructuredOutput(
      windowAppeared: false,
      windowSize: null,
      titleMatch: null,
      screenshotPath: null,
      processOutput: stdoutLines.join('\n'),
      processErrors: stderrLines.join('\n'),
      passed: false,
    );
    exit(1);
  }
  print('Window found.');

  // Give Flutter time to render the first frame.
  await Future<void>.delayed(const Duration(seconds: 3));

  // Get window size — non-zero proves the renderer initialized.
  final windowSize = await _getWindowSize(bundleName);
  print('Window size: $windowSize');

  final sizeValues = windowSize
      .split(',')
      .map((s) => int.tryParse(s.trim()) ?? 0)
      .toList();
  final width = sizeValues.isNotEmpty ? sizeValues[0] : 0;
  final height = sizeValues.length > 1 ? sizeValues[1] : 0;
  final hasNonZeroSize = width > 100 && height > 100;

  // Check window title bar text.
  String? titleBarText;
  bool? titleMatch;
  if (expectedTitle != null) {
    titleBarText = await _getWindowTitle(bundleName);
    print('Window title: $titleBarText');
    titleMatch =
        titleBarText != null &&
        titleBarText.toLowerCase().contains(expectedTitle.toLowerCase());
  }

  // Query accessibility tree (informational only).
  final accessibilityOutput = await _getAccessibilityTree(bundleName);
  print('Accessibility tree (first 500 chars):');
  print(
    accessibilityOutput.length > 500
        ? accessibilityOutput.substring(0, 500)
        : accessibilityOutput,
  );

  // Best-effort screenshot.
  final screenshotPath =
      '${Directory.systemTemp.path}/${bundleName}_screenshot.png';
  final screenshotSize = await _takeScreenshot(bundleName, screenshotPath);
  if (screenshotSize > 0) {
    print('Screenshot: $screenshotPath ($screenshotSize bytes)');
  } else {
    print(
      'Screenshot: unavailable (screencapture failed — expected in some CI environments)',
    );
  }

  // Quit the app.
  appProcess.kill();
  await _quitApp(bundleName);
  caffeinate.kill();

  // Check process output for Flutter engine messages.
  final allOutput = [...stdoutLines, ...stderrLines].join('\n');
  final hasEngineMsg =
      allOutput.contains('flutter') ||
      allOutput.contains('Flutter') ||
      allOutput.contains('Dart');

  // Report results.
  print('');
  print('=== Results ===');
  print('Window appeared: yes');
  print(
    'Window size: ${width}x$height (${hasNonZeroSize ? "OK" : "TOO SMALL — FAIL"})',
  );
  if (expectedTitle != null) {
    print(
      'Window title contains "$expectedTitle": ${titleMatch == true ? "yes" : "no"}',
    );
  }
  if (screenshotSize > 0) {
    print('Screenshot: $screenshotPath ($screenshotSize bytes)');
  }
  print(
    'Flutter engine output detected: ${hasEngineMsg ? "yes" : "no (may be normal)"}',
  );
  print('Process stdout lines: ${stdoutLines.length}');
  print('Process stderr lines: ${stderrLines.length}');

  // Structured output for machine parsing.
  _printStructuredOutput(
    windowAppeared: true,
    windowSize: '${width}x$height',
    titleMatch: titleMatch,
    screenshotPath: screenshotSize > 0 ? screenshotPath : null,
    processOutput: stdoutLines.join('\n'),
    processErrors: stderrLines.join('\n'),
    passed: hasNonZeroSize,
  );

  // Pass if window appeared with non-zero size.
  print('');
  print(hasNonZeroSize ? 'PASS' : 'FAIL');
  exit(hasNonZeroSize ? 0 : 1);
}

void _printStructuredOutput({
  required bool windowAppeared,
  required String? windowSize,
  required bool? titleMatch,
  required String? screenshotPath,
  required String processOutput,
  required String processErrors,
  required bool passed,
}) {
  final result = {
    'window_appeared': windowAppeared,
    'window_size': windowSize,
    'title_match': titleMatch,
    'screenshot_path': screenshotPath,
    'process_stdout_lines': processOutput.split('\n').length,
    'process_stderr_lines': processErrors.split('\n').length,
    'passed': passed,
  };
  print('');
  print('--- JSON ---');
  print(jsonEncode(result));
  print('--- END JSON ---');
}

Future<bool> _pollFor(Duration timeout, Future<bool> Function() check) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await check()) return true;
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  return false;
}

Future<bool> _hasWindow(String processName) async {
  final result = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to get (count of windows of process "$processName")'
        .replaceAll(r'$processName', processName),
  ]);
  if (result.exitCode != 0) return false;
  final count = int.tryParse(result.stdout.toString().trim()) ?? 0;
  return count > 0;
}

Future<String> _getWindowSize(String processName) async {
  final result = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to tell process "$processName" to get size of window 1'
        .replaceAll(r'$processName', processName),
  ]);
  return result.stdout.toString().trim();
}

Future<String?> _getWindowTitle(String processName) async {
  final result = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to tell process "$processName" to get name of window 1'
        .replaceAll(r'$processName', processName),
  ]);
  if (result.exitCode != 0) return null;
  return result.stdout.toString().trim();
}

Future<String> _getAccessibilityTree(String processName) async {
  final result = await Process.run('osascript', [
    '-e',
    'tell application "System Events" to tell process "$processName" to get entire contents of window 1'
        .replaceAll(r'$processName', processName),
  ]);
  return '${result.stdout}\n${result.stderr}'.trim();
}

Future<int> _takeScreenshot(String processName, String outputPath) async {
  // Bring app to front and capture screen.
  final idResult = await Process.run('osascript', [
    '-e',
    '''
tell application "System Events"
  tell process "$processName"
    set frontmost to true
  end tell
end tell
delay 0.5
do shell script "screencapture -x $outputPath"
'''
        .replaceAll(r'$processName', processName)
        .replaceAll(r'$outputPath', outputPath),
  ]);

  final file = File(outputPath);
  if (idResult.exitCode == 0 && file.existsSync()) {
    return file.lengthSync();
  }
  return 0;
}

Future<void> _quitApp(String bundleName) async {
  await Process.run('osascript', [
    '-e',
    'tell application "$bundleName" to quit'.replaceAll(
      r'$bundleName',
      bundleName,
    ),
  ]);
  await Future<void>.delayed(const Duration(seconds: 2));
}

/// Core Graphics' view of the desktop session. `CGSSessionScreenIsLocked` is
/// in the session dictionary only while the screen is locked.
const _probeScript = r'''
ObjC.import('ApplicationServices');
ObjC.import('CoreGraphics');
var d = $.CGSessionCopyCurrentDictionary();
var locked = false;
if (d) {
  locked = !!ObjC.deepUnwrap(ObjC.castRefToObject(d))['CGSSessionScreenIsLocked'];
}
JSON.stringify({
  locked: locked,
  asleep: $.CGDisplayIsAsleep($.CGMainDisplayID()) !== 0,
  trusted: $.AXIsProcessTrusted(),
});
''';

Future<Map<String, Object?>> _probeSession() async {
  final result = await Process.run('osascript', [
    '-l',
    'JavaScript',
    '-e',
    _probeScript,
  ]);
  if (result.exitCode != 0) {
    throw StateError('osascript: ${result.stderr}');
  }
  return jsonDecode(result.stdout.toString().trim()) as Map<String, Object?>;
}

/// Gives a display woken by the `caffeinate -u` above up to 15s to light.
Future<void> _waitForDisplay() async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _probeSession())['asleep'] != true) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

/// Which of a locked screen, a sleeping display and an untrusted runner is
/// behind a missing window, with the remedy. A window System Events cannot
/// see looks the same in all three.
Future<String> _diagnoseSession() async {
  final Map<String, Object?> state;
  try {
    state = await _probeSession();
  } on StateError catch (e) {
    return 'Could not read the desktop session ($e). Check by hand that the '
        'screen is unlocked, the display awake and the terminal granted '
        'Accessibility.';
  }
  if (state['locked'] == true) {
    return 'The screen is locked: System Events sees no windows while it is, '
        'and Accessibility is not the problem. Unlock the Mac and re-run.';
  }
  if (state['asleep'] == true) {
    return 'The display is asleep and stayed asleep after `caffeinate -d -u`: '
        'System Events sees no windows while it is, and Accessibility is not '
        'the problem. Wake the Mac by hand and re-run.';
  }
  if (state['trusted'] == false) {
    return 'The terminal is not trusted for Accessibility. Grant it in '
        'System Settings > Privacy & Security > Accessibility, '
        '`killall "System Events"`, and re-run.';
  }
  return 'The screen is unlocked, the display awake and Accessibility '
      'granted: the app itself drew no window.';
}
