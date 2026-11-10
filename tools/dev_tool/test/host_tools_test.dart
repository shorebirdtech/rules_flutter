import 'dart:io';

import 'package:flutter_bazel_dev_tool/host_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The name a tool's file actually has on this platform.
String exeName(String name) => Platform.isWindows ? '$name.exe' : name;

/// A PATH value, separated the way this platform separates one.
String pathValue(List<String> entries) =>
    entries.join(Platform.isWindows ? ';' : ':');

/// Create [name] under [dir] (and any missing parents) and return its path.
String touch(String dir, String name) {
  final file = File(p.join(dir, name));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('');
  return file.path;
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('host_tools_test_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  String dir(String name) {
    final d = Directory(p.join(tmp.path, name))..createSync(recursive: true);
    return d.path;
  }

  HostTool tool({
    List<String> candidates = const [],
    List<String>? pathNames,
    Map<String, String> environment = const {},
  }) => HostTool(
    name: 'widget',
    purpose: 'do the thing',
    remedy: 'Install widget.',
    candidates: candidates,
    pathNames: pathNames,
    environment: environment,
  );

  group('HostTool.find', () {
    test('returns null when the tool is nowhere', () {
      expect(
        tool(
          candidates: [p.join(tmp.path, 'nope', exeName('widget'))],
          environment: {
            'PATH': pathValue([dir('empty')]),
          },
        ).find(),
        isNull,
      );
    });

    test('prefers a candidate over PATH', () {
      final sdk = dir('sdk');
      final onPath = dir('bin');
      final candidate = touch(sdk, exeName('widget'));
      touch(onPath, exeName('widget'));

      expect(
        tool(
          candidates: [candidate],
          environment: {
            'PATH': pathValue([onPath]),
          },
        ).find(),
        candidate,
      );
    });

    test('searches PATH entries in order', () {
      final first = dir('first');
      final second = dir('second');
      final found = touch(second, exeName('widget'));

      expect(
        tool(
          environment: {
            'PATH': pathValue([first, second]),
          },
        ).find(),
        found,
      );
    });

    // A directory named like the binary is not the binary; returning it would
    // produce an exec-format failure far from here.
    test('ignores a directory with the tool name', () {
      final onPath = dir('bin');
      Directory(p.join(onPath, exeName('widget'))).createSync();

      expect(
        tool(
          environment: {
            'PATH': pathValue([onPath]),
          },
        ).find(),
        isNull,
      );
    });

    test('skips PATH entirely when the tool has no PATH names', () {
      final onPath = dir('bin');
      touch(onPath, exeName('widget'));

      expect(
        tool(
          pathNames: const [],
          environment: {
            'PATH': pathValue([onPath]),
          },
        ).find(),
        isNull,
      );
    });
  });

  group('HostTool.require', () {
    test('names the tool, what it is for, where it looked, and the fix', () {
      final missing = p.join(tmp.path, 'sdk', exeName('widget'));
      final onPath = dir('bin');

      expect(
        () => tool(
          candidates: [missing],
          environment: {
            'PATH': pathValue([onPath]),
          },
        ).require(),
        throwsA(
          isA<MissingHostToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Could not find widget'),
              contains('needed to do the thing'),
              contains(missing),
              contains('widget on PATH'),
              contains('Install widget.'),
            ),
          ),
        ),
      );
    });

    // An empty PATH is a real misconfiguration (a stripped environment in CI,
    // say) and reads as a bug in the search unless the message says so.
    test('says so when PATH is empty', () {
      expect(
        () => tool(environment: const {'PATH': ''}).require(),
        throwsA(
          isA<MissingHostToolException>().having(
            (e) => e.message,
            'message',
            contains('widget on PATH (PATH is empty)'),
          ),
        ),
      );
    });

    test('returns the path when the tool is there', () {
      final found = touch(dir('bin'), exeName('widget'));
      expect(tool(candidates: [found]).require(), found);
    });
  });

  group('chromeTool', () {
    test('CHROME_EXECUTABLE wins over the installed browser', () {
      final chrome = touch(dir('bin'), exeName('chrome'));
      expect(
        chromeTool(environment: {'CHROME_EXECUTABLE': chrome}).find(),
        chrome,
      );
    });

    // Asserted on the remedy rather than on a failed lookup: this machine may
    // well have Chrome installed, and a test that only holds where it is
    // absent proves nothing where it is not.
    test('offers both ways out — install it, or run somewhere else', () {
      expect(
        chromeTool(environment: const {}).remedy,
        allOf(contains('CHROME_EXECUTABLE'), contains('-d macos')),
      );
    });
  });
}
