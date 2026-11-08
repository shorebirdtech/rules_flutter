import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../check_android_classes.dart';

/// A zip archive of [entries], stored.
Uint8List zip(Map<String, List<int>> entries) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  for (final MapEntry(key: name, value: content) in entries.entries) {
    final offset = out.length;
    final crc = _crc32(content);
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint32(14, crc, Endian.little)
      ..setUint32(18, content.length, Endian.little)
      ..setUint32(22, content.length, Endian.little)
      ..setUint16(26, name.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(name.codeUnits)
      ..add(content);
    final header = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint32(16, crc, Endian.little)
      ..setUint32(20, content.length, Endian.little)
      ..setUint32(24, content.length, Endian.little)
      ..setUint16(28, name.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(header.buffer.asUint8List())
      ..add(name.codeUnits);
  }
  final directory = out.length;
  final size = central.length;
  out.add(central.takeBytes());
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, size, Endian.little)
    ..setUint32(16, directory, Endian.little);
  out.add(end.buffer.asUint8List());
  return out.takeBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

void main() {
  group('zipCrcs', () {
    test('reads each entry\'s CRC-32 from the central directory', () {
      final crcs = zipCrcs(
        zip({
          'a/A.class': [1, 2],
          'b.txt': [],
        }),
      );
      expect(crcs, {
        'a/A.class': _crc32([1, 2]),
        'b.txt': 0,
      });
    });

    test('rejects what is not a zip archive', () {
      expect(() => zipCrcs(Uint8List(40)), throwsFormatException);
    });
  });

  group('comparedClass', () {
    test('compares classes', () {
      expect(
        comparedClass('androidx/activity/ComponentActivityKt.class'),
        isTrue,
      );
      expect(comparedClass('Top.class'), isTrue);
      expect(comparedClass(r'a/Rx$1.class'), isTrue);
    });

    test('leaves out resource classes, which android_binary replaces', () {
      expect(comparedClass('androidx/core/R.class'), isFalse);
      expect(comparedClass(r'androidx/core/R$string.class'), isFalse);
    });

    test('leaves out module descriptors and META-INF', () {
      expect(comparedClass('module-info.class'), isFalse);
      expect(comparedClass('META-INF/versions/9/a/A.class'), isFalse);
      expect(comparedClass('a/a.txt'), isFalse);
    });
  });

  group('conflicts', () {
    final ktx = Jar('ktx.jar', 'androidx.activity:activity-ktx:1.5.1');
    final main = Jar('main.jar', 'androidx.activity:activity:1.9.0');
    final other = Jar('other.jar', 'com.example:other:1');

    test('groups the classes two jars define differently', () {
      final found = conflicts(
        [ktx, main, other],
        {
          ktx: {'a/B.class': 1, 'a/A.class': 1, 'a/Same.class': 5},
          main: {'a/A.class': 2, 'a/B.class': 3, 'a/Same.class': 5},
          other: {'o/O.class': 4},
        },
      );
      expect(found, hasLength(1));
      expect(found.single.jars, [ktx, main]);
      expect(found.single.classes, ['a/A.class', 'a/B.class']);
    });

    test('finds none in classes of the same bytes, or resource classes', () {
      final found = conflicts(
        [ktx, main],
        {
          ktx: {'a/A.class': 1, r'a/R$id.class': 1},
          main: {'a/A.class': 1, r'a/R$id.class': 2},
        },
      );
      expect(found, isEmpty);
    });
  });

  group('conflictMessage', () {
    test('is null without conflicts', () {
      expect(conflictMessage([], app: '//:app', report: '//:r'), isNull);
    });

    test('names both jars, the classes, and how to fix it', () {
      final message = conflictMessage(
        [
          Conflict(
            [
              Jar('ktx.jar', 'androidx.activity:activity-ktx:1.5.1 (@m//:k)'),
              Jar('main.jar', 'androidx.activity:activity:1.9.0 (@m//:a)'),
            ],
            ['a/A.class', 'a/B.class', 'a/C.class', 'a/D.class'],
          ),
        ],
        app: '//:app',
        report: '//:app_maven_artifacts',
      )!;
      expect(message, contains('//:app links jars'));
      expect(
        message,
        contains('androidx.activity:activity-ktx:1.5.1 (@m//:k)'),
      );
      expect(message, contains('androidx.activity:activity:1.9.0 (@m//:a)'));
      expect(
        message,
        contains('4 classes, such as a/A.class, a/B.class, a/C.class'),
      );
      expect(message, contains('bazel run //:app_maven_artifacts'));
      expect(message, contains('REPIN=1 bazel run @rules_android_maven//:pin'));
    });
  });

  group('run', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('classes'));
    tearDown(() => dir.deleteSync(recursive: true));

    String write(String name, Map<String, List<int>> entries) {
      final file = File('${dir.path}/$name')..writeAsBytesSync(zip(entries));
      return file.path;
    }

    List<String> params(List<String> jarArgs) {
      final file = File('${dir.path}/params')
        ..writeAsStringSync(
          [
            '--app',
            '//:app',
            '--report',
            '//:r',
            '--stamp',
            '${dir.path}/stamp',
            ...jarArgs,
          ].join('\n'),
        );
      return ['@${file.path}'];
    }

    test('writes the stamp when every class has one definition', () {
      final a = write('a.jar', {
        'a/A.class': [1],
      });
      final b = write('b.jar', {
        'a/A.class': [1],
        'b/B.class': [2],
      });
      expect(run(params(['--jar', a, 'a', '--jar', b, 'b'])), 0);
      expect(File('${dir.path}/stamp').existsSync(), isTrue);
    });

    test('fails without a stamp when two jars define a class differently', () {
      final a = write('a.jar', {
        'a/A.class': [1],
      });
      final b = write('b.jar', {
        'a/A.class': [2],
      });
      expect(run(params(['--jar', a, 'a', '--jar', b, 'b'])), 1);
      expect(File('${dir.path}/stamp').existsSync(), isFalse);
    });
  });
}
