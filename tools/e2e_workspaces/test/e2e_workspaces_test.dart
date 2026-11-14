import 'dart:io';

import 'package:test/test.dart';

import '../e2e_workspaces.dart';

void main() {
  group('findWorkspaces', () {
    late Directory tmp;
    late Directory e2e;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('find_workspaces');
      e2e = Directory('${tmp.path}/e2e')..createSync();
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    void module(String dir) {
      Directory('${e2e.path}/$dir').createSync(recursive: true);
      File('${e2e.path}/$dir/MODULE.bazel').writeAsStringSync('');
    }

    test('finds workspaces at any depth, sorted', () {
      module('smoke');
      module('nested/inner');
      module('app');
      expect(findWorkspaces(e2e), [
        'e2e/app',
        'e2e/nested/inner',
        'e2e/smoke',
      ]);
    });

    test('ignores directories with no MODULE.bazel', () {
      module('app');
      Directory('${e2e.path}/_compare').createSync();
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('does not look inside a workspace', () {
      module('app');
      module('app/macos/vendored');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });

    test('skips node_modules and bazel output links', () {
      module('node_modules/pkg');
      module('bazel-out/x');
      module('app');
      expect(findWorkspaces(e2e), ['e2e/app']);
    });
  });
}
