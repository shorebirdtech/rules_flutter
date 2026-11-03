import 'dart:convert';
import 'dart:io';

import 'package:rules_flutter_e2e_testing/host_leaks.dart';
import 'package:test/test.dart';

void main() {
  const base =
      '/Users/dev/Library/Caches/bazel/_bazel_dev/'
      '0123456789abcdef0123456789abcdef';
  final markers = HostMarkers.forBuildHost(
    ['/nowhere'],
    env: const {'HOME': '/Users/dev', 'USER': 'dev'},
  );

  List<String> labels(String text) => [
    for (final leak in markers.inBytes(utf8.encode(text), source: 'x'))
      leak.label,
  ];

  group('HostMarkers', () {
    test('finds a sandboxed execroot path in a kernel-like blob', () {
      final found = labels(
        'zz file://$base/sandbox/darwin-sandbox/161/execroot/_main/lib/a.dart',
      );
      expect(found, containsAll(['execroot', 'sandbox slot']));
      expect(found, contains('Bazel output base'));
    });

    test('finds the home directory and the user name', () {
      expect(labels('/Users/dev/code/x.dart'), hasLength(2));
      expect(
        labels('/Users/dev/code'),
        containsAll(['home directory /Users/dev', 'user name "dev"']),
      );
    });

    test('does not mistake the SDK own strings for the host', () {
      expect(
        labels(
          'iframe.sandbox file:///home/myself/images/image.png '
          'file:///C:/Users/myself/Documents/image.png '
          'org-dartlang-app:///lib/main.dart package:flutter/material.dart',
        ),
        isEmpty,
      );
    });

    test('reports each marker once, with its count and first context', () {
      final leaks = markers.inBytes(
        latin1.encode('a /execroot/ b /execroot/ c'),
        source: 'f',
      );
      expect(leaks, hasLength(1));
      expect(leaks.single.count, 2);
      expect(leaks.single.context, 'a /execroot/ b /execroot/ c');
    });

    test('sees a path inside binary data, and shows it printable', () {
      final leaks = markers.inBytes([
        0,
        255,
        ...utf8.encode('/execroot/'),
        1,
      ], source: 'f');
      expect(leaks.single.context, '../execroot/.');
    });
  });

  group('outputBaseOf', () {
    test('reads the base from a sandboxed and an unsandboxed execroot', () {
      expect(
        outputBaseOf('$base/sandbox/darwin-sandbox/3/execroot/_main/a'),
        base,
      );
      expect(outputBaseOf('$base/execroot/_main/bazel-out/x'), base);
      expect(outputBaseOf('/just/a/path'), isNull);
    });
  });

  group('inTree', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('host_leaks_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('names the file, relative to the scanned directory', () {
      Directory('${dir.path}/a/b').createSync(recursive: true);
      File('${dir.path}/a/b/c.dill').writeAsStringSync('/execroot/');
      File('${dir.path}/clean.txt').writeAsStringSync('nothing');
      final leaks = markers.inTree(dir.path);
      expect(leaks.map((l) => l.source), ['a/b/c.dill']);
    });
  });

  group('gzipHeaderHostDependence', () {
    final clean = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 255];
    test('accepts a header naming no host', () {
      expect(gzipHeaderHostDependence(clean), isEmpty);
    });
    test('flags the OS byte of a Darwin or a Unix compressor', () {
      for (final os in [3, 19, 10, 0]) {
        expect(
          gzipHeaderHostDependence([...clean.take(9), os]),
          [contains('OS byte is $os')],
        );
      }
    });
    test('flags a modification time', () {
      expect(
        gzipHeaderHostDependence([0x1f, 0x8b, 8, 0, 1, 0, 0, 0, 0, 255]),
        [contains('modification time')],
      );
    });
    test('rejects anything that is not gzip', () {
      expect(gzipHeaderHostDependence([1, 2, 3]), ['not a gzip stream']);
    });
  });
}
