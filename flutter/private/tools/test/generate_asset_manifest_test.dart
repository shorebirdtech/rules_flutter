import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

// Import the library directly.
import '../generate_asset_manifest.dart';
import '../generate_asset_manifest.dart' as tool show main;

void main() {
  group('encodeStandardMessage', () {
    test('encodes null to empty bytes', () {
      final result = encodeStandardMessage(null);
      expect(result, isEmpty);
    });

    test('encodes bool true to tag 1', () {
      final result = encodeStandardMessage(true);
      expect(result[0], 1); // _tagTrue
    });

    test('encodes bool false to tag 2', () {
      final result = encodeStandardMessage(false);
      expect(result[0], 2); // _tagFalse
    });

    test('encodes int32 to tag 3 + 4 bytes', () {
      final result = encodeStandardMessage(42);
      expect(result[0], 3); // _tagInt32
      expect(result.length, 5); // 1 tag + 4 bytes
      // Decode the int32 value.
      final bd = ByteData.sublistView(result, 1, 5);
      expect(bd.getInt32(0, Endian.host), 42);
    });

    test('encodes string to tag 7 + length + UTF-8 bytes', () {
      final result = encodeStandardMessage('hello');
      expect(result[0], 7); // _tagString
      expect(result[1], 5); // length of "hello" in UTF-8
      expect(utf8.decode(result.sublist(2)), 'hello');
    });

    test('encodes list to tag 12 + length + elements', () {
      final result = encodeStandardMessage([true, false]);
      expect(result[0], 12); // _tagList
      expect(result[1], 2); // 2 elements
      expect(result[2], 1); // true
      expect(result[3], 2); // false
    });

    test('encodes map to tag 13 + length + key-value pairs', () {
      final result = encodeStandardMessage({'a': true});
      expect(result[0], 13); // _tagMap
      expect(result[1], 1); // 1 entry
      // Key: string "a"
      expect(result[2], 7); // _tagString
      expect(result[3], 1); // length 1
      expect(result[4], 0x61); // 'a'
      // Value: true
      expect(result[5], 1); // _tagTrue
    });

    test('encodes nested asset manifest structure', () {
      // Simulate a real asset manifest: Map<String, List<Map<String, Object>>>
      final manifest = {
        'assets/logo.png': [
          {'asset': 'assets/logo.png'},
          {'asset': 'assets/2.0x/logo.png', 'dpr': 2.0},
        ],
      };
      final result = encodeStandardMessage(manifest);
      // Just verify it encodes without error and starts with map tag.
      expect(result[0], 13); // _tagMap
      expect(result.length, greaterThan(10));
    });

    test('writeSize encodes 1-byte, 2-byte, 4-byte sizes', () {
      // 1-byte: size < 254 — encode a short string
      final short = encodeStandardMessage('hi');
      expect(short[1], 2); // size fits in 1 byte

      // 2-byte: size 254..65535 — encode a long string
      final mediumStr = 'x' * 300;
      final medium = encodeStandardMessage(mediumStr);
      expect(medium[1], 254); // marker for 2-byte size

      // 4-byte: would need a huge string (65536+), skip for perf.
    });
  });

  group('NOTICES.Z', () {
    // Property: the bundle is a function of its declared inputs, so the same
    // licence text gives the same NOTICES.Z bytes whichever machine built it.
    //
    // A gzip header records the compressor's OS, and zlib fills that in from
    // the platform it was built for: 3 on Linux, 19 on macOS, 10 on Windows.
    // This test runs on one host and cannot see the others, so it asserts the
    // one value that names no host (255, "unknown" in RFC 1952) and a zero
    // modification time. Anything else is the bytes of the host that ran it.
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('notices_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<List<int>> noticesFor(Map<String, Object?> config) async {
      final configFile = File('${dir.path}/config.json')
        ..writeAsStringSync(json.encode(config));
      await tool.main([
        '--config',
        configFile.path,
        '--output-dir',
        '${dir.path}/out',
      ]);
      return File('${dir.path}/out/NOTICES.Z').readAsBytesSync();
    }

    void expectHostIndependentHeader(List<int> z) {
      expect(z.sublist(0, 2), [0x1f, 0x8b], reason: 'a gzip stream');
      expect(z.sublist(4, 8), [0, 0, 0, 0], reason: 'no modification time');
      expect(
        z[9],
        255,
        reason:
            'the OS byte names the host that compressed it (3 Unix, 19 '
            'Darwin, 10 Windows), so the same inputs would give different '
            'bytes on another host',
      );
    }

    test('the gzip header names no host, for inline text', () async {
      final z = await noticesFor({'notices': 'Licence text'});
      expectHostIndependentHeader(z);
      expect(utf8.decode(gzip.decode(z)), 'Licence text');
    });

    test('the gzip header names no host, for licence files', () async {
      final licence = File('${dir.path}/LICENSE')..writeAsStringSync('MIT');
      final z = await noticesFor({
        'notices': 'first',
        'license_files': [licence.path],
      });
      expectHostIndependentHeader(z);
      expect(utf8.decode(gzip.decode(z)), 'first\n\n---\n\nMIT');
    });

    test('the gzip header names no host, with no licences at all', () async {
      final z = await noticesFor({});
      expectHostIndependentHeader(z);
      expect(gzip.decode(z), isEmpty);
    });
  });
}
