import 'dart:io';

import 'package:test/test.dart';

import '../apple_xcframeworks_export.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('xcframeworks_export'));
  tearDown(() => dir.deleteSync(recursive: true));

  void write(String relative, String content) => File('${dir.path}/$relative')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  ExportConfig config(String mode) => ExportConfig(
    tree: '${dir.path}/tree',
    package: 'app',
    platform: 'ios',
    mode: mode,
  );

  test('writes under build/<platform>/framework of the package', () {
    expect(
      outputDirectory(
        config('Release'),
        [],
        workspace: '/ws',
        workingDirectory: '/ws/app',
      ),
      '/ws/app/build/ios/framework',
    );
  });

  test('--output is relative to where bazel run ran', () {
    expect(
      outputDirectory(
        config('Release'),
        ['--output=out'],
        workspace: '/ws',
        workingDirectory: '/ws/app',
      ),
      '/ws/app/out',
    );
    expect(
      () => outputDirectory(
        config('Release'),
        ['--bogus'],
        workspace: '/ws',
        workingDirectory: '/ws',
      ),
      throwsFormatException,
    );
  });

  test('replaces its mode, keeps the others, and says they are older', () {
    write('tree/Release/App.xcframework/Info.plist', 'new');
    write('tree/GeneratedPluginRegistrant.m', 'registrant');
    write('out/Release/App.xcframework/Info.plist', 'old');
    write('out/Release/Stale.xcframework/Info.plist', 'stale');
    write('out/Debug/App.xcframework/Info.plist', 'debug');

    final lines = exportTree(config('Release'), '${dir.path}/out');

    String read(String path) => File('${dir.path}/$path').readAsStringSync();
    expect(read('out/Release/App.xcframework/Info.plist'), 'new');
    expect(
      File('${dir.path}/out/Release/Stale.xcframework/Info.plist').existsSync(),
      isFalse,
    );
    expect(read('out/Debug/App.xcframework/Info.plist'), 'debug');
    expect(read('out/GeneratedPluginRegistrant.m'), 'registrant');
    expect(lines.join('\n'), contains('Debug is from an earlier run'));
    expect(lines.join('\n'), contains('FlutterPluginRegistrant.xcframework'));
  });
}
