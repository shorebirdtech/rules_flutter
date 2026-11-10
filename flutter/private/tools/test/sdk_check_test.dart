import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';

import '../sdk_check.dart';

const hashA = '0451907c2eaa8467e848c0067bfe8ed4';
const hashB = '9f3c0000000000000000000000000001';
const hashC = '1111111111111111aaaaaaaaaaaaaaaa';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('sdk_check'));
  tearDown(() => dir.deleteSync(recursive: true));

  Artifact write(String name, List<int> bytes) {
    final file = File('${dir.path}/$name')..writeAsBytesSync(bytes);
    return Artifact('//label:$name', file.path);
  }

  /// A binary holding [hashes] as NUL-terminated strings among other bytes.
  Artifact binary(String name, List<String> hashes) => write(name, [
    ...utf8.encode('ELF junk\x00'),
    for (final h in hashes) ...[...utf8.encode(h), 0, 1, 2, 3],
    ...utf8.encode('tail'),
  ]);

  Artifact dill(
    String name, {
    int format = 138,
    String sdkHash = '0000000000',
  }) {
    final header = ByteData(8)..setUint32(4, format);
    return write(name, [
      0x90,
      0xab,
      0xcd,
      0xef,
      ...header.buffer.asUint8List(4),
      ...ascii.encode(sdkHash),
      0,
      6,
      3,
    ]);
  }

  Map<String, Object?> checkOf({
    String mode = 'release',
    Artifact? engine,
    Artifact? gen,
    Artifact? engineDill,
    Artifact? dartDill,
    Artifact? runtime,
    Map<String, Object?> record = const {},
  }) => check(
    mode: mode,
    engineBinary: engine ?? binary('engine', [hashA]),
    genSnapshot: mode == 'debug' ? null : gen ?? binary('gen', [hashA]),
    enginePlatformDill: engineDill ?? dill('engine.dill'),
    dartPlatformDill: dartDill ?? dill('dart.dill'),
    dartaotruntime: runtime ?? binary('runtime', [hashA]),
    record: record,
  );

  String failureOf(void Function() body) {
    try {
      body();
    } on SdkCheckFailure catch (failure) {
      return failure.message;
    }
    fail('expected a SdkCheckFailure');
  }

  group('snapshot hash', () {
    test('one shared hash passes and is recorded', () {
      final record = checkOf();
      expect(record['snapshot_hash'], hashA);
      expect(record['kernel'], {'format': 138, 'sdk_hash': '0000000000'});
    });

    test('a mismatch names both artifacts and both hashes', () {
      final message = failureOf(
        () => checkOf(
          gen: binary('gen', [hashB]),
          engine: binary('engine', [hashA]),
        ),
      );
      expect(message, contains('does not match itself for release'));
      expect(message, contains('//label:gen'));
      expect(message, contains('${dir.path}/gen'));
      expect(message, contains('snapshot hash $hashB'));
      expect(message, contains('//label:engine'));
      expect(message, contains('${dir.path}/engine'));
      expect(message, contains('snapshot hash $hashA'));
      expect(message, contains('same Dart'));
    });

    test('an unrelated extra candidate does not break the match', () {
      final record = checkOf(
        engine: binary('engine', [hashC, hashA]),
        runtime: binary('runtime', [hashB, hashA]),
      );
      expect(record['snapshot_hash'], hashA);
    });

    test('several shared hashes fail as undeterminable', () {
      final message = failureOf(
        () => checkOf(
          gen: binary('gen', [hashA, hashC]),
          engine: binary('engine', [hashC, hashA]),
        ),
      );
      expect(message, contains('cannot be determined'));
      expect(message, contains(hashA));
      expect(message, contains(hashC));
      expect(message, contains('//label:gen'));
      expect(message, contains('//label:engine'));
    });

    test('no candidate in a file fails as a mismatch', () {
      final message = failureOf(
        () => checkOf(gen: write('gen', utf8.encode('no hash here'))),
      );
      expect(message, contains('does not match itself'));
      expect(message, contains('no snapshot hash found'));
    });

    test('a hex run not followed by NUL is ignored', () {
      final message = failureOf(
        () => checkOf(
          engine: write('engine', [...utf8.encode(hashA), ...utf8.encode('x')]),
        ),
      );
      expect(message, contains('no snapshot hash found'));
    });

    test('a hex run preceded by a hex character is ignored', () {
      final message = failureOf(
        () => checkOf(engine: write('engine', [...utf8.encode('f$hashA'), 0])),
      );
      expect(message, contains('no snapshot hash found'));
    });

    test('a hex run preceded by a letter is ignored', () {
      final message = failureOf(
        () => checkOf(engine: write('engine', [...utf8.encode('z$hashA'), 0])),
      );
      expect(message, contains('no snapshot hash found'));
    });

    test('a run of 31 or 33 hex characters is ignored', () {
      final message = failureOf(
        () => checkOf(
          engine: write('engine', [
            ...utf8.encode(hashA.substring(1)),
            0,
            ...utf8.encode('${hashA}0'),
            0,
          ]),
        ),
      );
      expect(message, contains('no snapshot hash found'));
    });

    test('a preceding byte outside [0-9a-z] is tolerated', () {
      final record = checkOf(
        engine: write('engine', [
          ...utf8.encode('A='),
          ...utf8.encode(hashA),
          0,
        ]),
      );
      expect(record['snapshot_hash'], hashA);
    });

    test('a candidate straddling a read boundary is found', () {
      final bytes = [...List.filled(5, 0), ...utf8.encode(hashA), 0];
      final artifact = write('file', bytes);
      for (var chunk = 1; chunk < bytes.length; chunk++) {
        expect(snapshotHashCandidates(artifact.path, chunkSize: chunk), {
          hashA,
        }, reason: 'chunk size $chunk');
      }
    });
  });

  group('same Dart', () {
    test('a dartaotruntime of another hash fails naming it', () {
      final message = failureOf(
        () => checkOf(runtime: binary('runtime', [hashB])),
      );
      expect(message, contains('Dart SDK does not match'));
      expect(message, contains('//label:runtime'));
      expect(message, contains('snapshot hash $hashB'));
      expect(message, contains('//label:engine'));
      expect(message, isNot(contains('does not match itself')));
    });

    test('several shared with dartaotruntime fail as undeterminable', () {
      final message = failureOf(
        () => checkOf(
          engine: binary('engine', [hashA, hashB]),
          gen: binary('gen', [hashA]),
          runtime: binary('runtime', [hashA, hashB]),
        ),
      );
      expect(message, contains('Dart SDK cannot be determined'));
      expect(message, contains('//label:runtime'));
    });

    test('in AOT the runtime hash must be the gen_snapshot one', () {
      // The engine holds both; gen_snapshot picks A and the runtime B.
      final message = failureOf(
        () => checkOf(
          engine: binary('engine', [hashA, hashB]),
          gen: binary('gen', [hashA]),
          runtime: binary('runtime', [hashB]),
        ),
      );
      expect(message, contains('Dart SDK does not match'));
      expect(message, contains('//label:gen'));
      expect(message, contains('//label:runtime'));
      expect(message, contains('//label:engine'));
      expect(message, contains(hashA));
      expect(message, contains(hashB));
    });
  });

  group('debug', () {
    test('records the hash the engine shares with dartaotruntime', () {
      final record = checkOf(mode: 'debug');
      expect(record['snapshot_hash'], hashA);
    });

    test('fails when the engine and dartaotruntime differ', () {
      final message = failureOf(
        () => checkOf(mode: 'debug', runtime: binary('runtime', [hashB])),
      );
      expect(message, contains('Dart SDK does not match the Flutter engine'));
      expect(message, contains('for debug'));
    });

    test('refuses a gen_snapshot', () {
      expect(
        () => check(
          mode: 'debug',
          engineBinary: binary('engine', [hashA]),
          genSnapshot: binary('gen', [hashA]),
          enginePlatformDill: dill('engine.dill'),
          dartPlatformDill: dill('dart.dill'),
          dartaotruntime: binary('runtime', [hashA]),
          record: const {},
        ),
        throwsA(isA<SdkCheckFailure>()),
      );
    });

    test('profile and release require one', () {
      for (final mode in ['profile', 'release']) {
        expect(
          () => check(
            mode: mode,
            engineBinary: binary('engine', [hashA]),
            enginePlatformDill: dill('engine.dill'),
            dartPlatformDill: dill('dart.dill'),
            dartaotruntime: binary('runtime', [hashA]),
            record: const {},
          ),
          throwsA(isA<SdkCheckFailure>()),
        );
      }
    });
  });

  group('kernel', () {
    test('equal headers pass', () {
      final record = checkOf(
        engineDill: dill('e.dill', sdkHash: 'abcdef0123'),
        dartDill: dill('d.dill', sdkHash: 'abcdef0123'),
      );
      expect(record['kernel'], {'format': 138, 'sdk_hash': 'abcdef0123'});
    });

    test('a zero hash on the Dart side matches and records the other', () {
      final record = checkOf(
        engineDill: dill('e.dill', sdkHash: 'abcdef0123'),
        dartDill: dill('d.dill'),
      );
      expect(record['kernel'], {'format': 138, 'sdk_hash': 'abcdef0123'});
    });

    test('a zero hash on the engine side matches and records the other', () {
      final record = checkOf(
        engineDill: dill('e.dill'),
        dartDill: dill('d.dill', sdkHash: 'abcdef0123'),
      );
      expect(record['kernel'], {'format': 138, 'sdk_hash': 'abcdef0123'});
    });

    test('two zero hashes record zeros', () {
      expect(checkOf()['kernel'], {'format': 138, 'sdk_hash': '0000000000'});
    });

    test('differing hashes fail naming both dills and both hashes', () {
      final message = failureOf(
        () => checkOf(
          engineDill: dill('e.dill', sdkHash: 'abcdef0123'),
          dartDill: dill('d.dill', sdkHash: '9876543210'),
        ),
      );
      expect(message, contains('//label:e.dill'));
      expect(message, contains('//label:d.dill'));
      expect(message, contains('${dir.path}/e.dill'));
      expect(message, contains('SDK hash abcdef0123 vs 9876543210'));
      expect(message, contains('different Dart revisions'));
      expect(message, isNot(contains('kernel format 138 vs')));
    });

    test('differing formats fail naming both dills and both formats', () {
      final message = failureOf(
        () => checkOf(
          engineDill: dill('e.dill', format: 138),
          dartDill: dill('d.dill', format: 139),
        ),
      );
      expect(message, contains('//label:e.dill'));
      expect(message, contains('//label:d.dill'));
      expect(message, contains('kernel format 138 vs 139'));
      expect(message, contains('different Dart revisions'));
    });

    test('a file that is not kernel fails', () {
      final message = failureOf(
        () => checkOf(
          engineDill: write('e.dill', utf8.encode('not kernel!!!!!!!!')),
        ),
      );
      expect(message, contains('Not a kernel file'));
      expect(message, contains('//label:e.dill'));
    });

    test('a truncated header fails', () {
      final message = failureOf(
        () => checkOf(dartDill: write('d.dill', [0x90, 0xab, 0xcd, 0xef, 0])),
      );
      expect(message, contains('Not a kernel file'));
    });
  });

  group('record', () {
    test('keeps the incoming keys and adds the check results', () {
      final record = checkOf(
        record: {
          'sdk': 'local',
          'engine': {'z': 1, 'a': 2},
        },
      );
      expect(record['sdk'], 'local');
      expect(record['engine'], {'z': 1, 'a': 2});
      expect(record.keys, containsAll(['snapshot_hash', 'kernel']));
    });

    test('is encoded with sorted keys, indented, with a trailing newline', () {
      final text = encodeRecord(
        checkOf(
          record: {
            'sdk': 'local',
            'engine': {'z': 1, 'a': 2},
          },
        ),
      );
      expect(text, endsWith('}\n'));
      expect(
        text,
        '{\n'
        '  "engine": {\n'
        '    "a": 2,\n'
        '    "z": 1\n'
        '  },\n'
        '  "kernel": {\n'
        '    "format": 138,\n'
        '    "sdk_hash": "0000000000"\n'
        '  },\n'
        '  "sdk": "local",\n'
        '  "snapshot_hash": "$hashA"\n'
        '}\n',
      );
    });

    test('the framework entry leaves out what names the machine', () {
      final file = File('${dir.path}/flutter_framework.json')
        ..writeAsStringSync(
          jsonEncode({
            'version': '3.50.0-1.0.pre',
            'commit': 'abc',
            'dirty': true,
            'origin': 'local',
            'path': '/Users/someone/src/flutter',
            'root': '/Users/someone/src/flutter',
            'checkout': r'C:\Users\someone\flutter',
            'cache': 'D:/cache/flutter',
            'share': r'\\server\flutter',
          }),
        );
      expect(frameworkRecord(file.path), {
        'version': '3.50.0-1.0.pre',
        'commit': 'abc',
        'dirty': true,
        'origin': 'local',
      });
    });
  });

  group('command line', () {
    late Artifact engine, gen, engineDill, dartDill, runtime;
    late File recordIn;
    late String recordOut;
    setUp(() {
      engine = binary('engine', [hashA]);
      gen = binary('gen', [hashA]);
      engineDill = dill('e.dill');
      dartDill = dill('d.dill');
      runtime = binary('runtime', [hashA]);
      recordIn = File('${dir.path}/in.json')
        ..writeAsStringSync('{"sdk": "local"}');
      recordOut = '${dir.path}/out.json';
    });

    List<String> args({String mode = 'release', bool withGen = true}) => [
      '--mode=$mode',
      '--engine-binary=${engine.path}',
      '--engine-label=${engine.label}',
      if (withGen) ...[
        '--gen-snapshot=${gen.path}',
        '--gen-snapshot-label=${gen.label}',
      ],
      '--engine-platform-dill=${engineDill.path}',
      '--engine-platform-dill-label=${engineDill.label}',
      '--dart-platform-dill=${dartDill.path}',
      '--dart-platform-dill-label=${dartDill.label}',
      '--dartaotruntime=${runtime.path}',
      '--dartaotruntime-label=${runtime.label}',
      '--record-in=${recordIn.path}',
      '--record-out=$recordOut',
    ];

    test('writes the record and exits 0', () {
      final err = StringBuffer();
      expect(run(args(), err: err), 0);
      expect(err.toString(), isEmpty);
      final written = jsonDecode(File(recordOut).readAsStringSync());
      expect(written, {
        'sdk': 'local',
        'snapshot_hash': hashA,
        'kernel': {'format': 138, 'sdk_hash': '0000000000'},
      });
    });

    test('a debug run takes no gen_snapshot', () {
      expect(run(args(mode: 'debug', withGen: false), err: StringBuffer()), 0);
      expect(File(recordOut).existsSync(), isTrue);
    });

    test('a failed check writes nothing, prints the message, exits 1', () {
      gen = binary('gen', [hashB]);
      final err = StringBuffer();
      expect(run(args(), err: err), 1);
      expect(File(recordOut).existsSync(), isFalse);
      expect(err.toString(), contains('snapshot hash $hashB'));
    });

    test('a missing flag exits 1 naming it', () {
      final err = StringBuffer();
      final partial = args()
        ..removeWhere((a) => a.startsWith('--dartaotruntime-label'));
      expect(run(partial, err: err), 1);
      expect(err.toString(), contains('--dartaotruntime-label'));
    });

    test('a file that does not exist exits 1 naming it', () {
      engine = Artifact(engine.label, '${dir.path}/missing');
      final err = StringBuffer();
      expect(run(args(), err: err), 1);
      expect(File(recordOut).existsSync(), isFalse);
      expect(err.toString(), contains('${dir.path}/missing'));
    });

    test('an unknown flag exits 1', () {
      final err = StringBuffer();
      expect(run([...args(), '--bogus=1'], err: err), 1);
      expect(err.toString(), contains('--bogus=1'));
    });

    test('a record that is not an object exits 1', () {
      recordIn.writeAsStringSync('[1]');
      final err = StringBuffer();
      expect(run(args(), err: err), 1);
      expect(File(recordOut).existsSync(), isFalse);
      expect(err.toString(), contains('not a JSON object'));
    });
  });

  group('an engine binary inside a jar', () {
    const entry = 'lib/arm64-v8a/libflutter.so';

    /// A zip of the given entries (name to bytes), each deflated or stored.
    Artifact jar(
      String name,
      Map<String, List<int>> entries, {
      bool deflate = true,
    }) {
      final out = BytesBuilder();
      final central = BytesBuilder();
      var count = 0;
      for (final MapEntry(key: entryName, value: data) in entries.entries) {
        final stored = deflate ? ZLibCodec(raw: true).encode(data) : data;
        final nameBytes = utf8.encode(entryName);
        final offset = out.length;
        final local = ByteData(30)
          ..setUint32(0, 0x04034b50, Endian.little)
          ..setUint16(8, deflate ? 8 : 0, Endian.little)
          ..setUint32(18, stored.length, Endian.little)
          ..setUint32(22, data.length, Endian.little)
          ..setUint16(26, nameBytes.length, Endian.little);
        out
          ..add(local.buffer.asUint8List())
          ..add(nameBytes)
          ..add(stored);
        final header = ByteData(46)
          ..setUint32(0, 0x02014b50, Endian.little)
          ..setUint16(10, deflate ? 8 : 0, Endian.little)
          ..setUint32(20, stored.length, Endian.little)
          ..setUint32(24, data.length, Endian.little)
          ..setUint16(28, nameBytes.length, Endian.little)
          ..setUint32(42, offset, Endian.little);
        central
          ..add(header.buffer.asUint8List())
          ..add(nameBytes);
        count++;
      }
      final directoryOffset = out.length;
      out.add(central.toBytes());
      final end = ByteData(22)
        ..setUint32(0, 0x06054b50, Endian.little)
        ..setUint16(8, count, Endian.little)
        ..setUint16(10, count, Endian.little)
        ..setUint32(12, central.length, Endian.little)
        ..setUint32(16, directoryOffset, Endian.little);
      out.add(end.buffer.asUint8List());
      final file = File('${dir.path}/$name')..writeAsBytesSync(out.toBytes());
      return Artifact('//label:$name', file.path, entry: entry);
    }

    List<int> library(List<String> hashes) => [
      ...utf8.encode('ELF junk\x00'),
      for (final h in hashes) ...[...utf8.encode(h), 0, 1, 2, 3],
      // Enough bytes after the hash that deflate needs several blocks.
      for (var i = 0; i < 200000; i++) (i * 7) & 0xff,
    ];

    for (final deflate in [true, false]) {
      test('its hash is the one the check compares (deflate $deflate)', () {
        final record = checkOf(
          engine: jar('engine.jar', {
            'classes.dex': [1, 2, 3],
            entry: library([hashA]),
          }, deflate: deflate),
        );
        expect(record['snapshot_hash'], hashA);
      });
    }

    test(
      'a hash that differs from gen_snapshot is a mismatch naming the entry',
      () {
        final message = failureOf(
          () => checkOf(
            engine: jar('engine.jar', {
              entry: library([hashB]),
            }),
          ),
        );
        expect(message, contains('does not match itself'));
        expect(message, contains('snapshot hash $hashB'));
        expect(message, contains('entry $entry'));
      },
    );

    test('a jar without the entry fails naming it', () {
      final message = failureOf(
        () => checkOf(
          engine: jar('engine.jar', {
            'classes.dex': [1],
          }),
        ),
      );
      expect(message, contains('no such entry'));
      expect(message, contains(entry));
    });

    test('a file that is not a zip fails', () {
      final bogus = write('engine.jar', utf8.encode('not a zip'));
      final message = failureOf(
        () => checkOf(
          engine: Artifact(bogus.label, bogus.path, entry: entry),
        ),
      );
      expect(message, contains('not a zip archive'));
    });
  });

  group('web', () {
    Map<String, Object?> webOf({
      List<Artifact>? webDills,
      Artifact? dartDill,
      Map<String, Object?> record = const {},
    }) => checkWeb(
      webPlatformDills:
          webDills ??
          [
            dill('dart2js.dill', sdkHash: 'abcdef0123'),
            dill('dart2wasm.dill', sdkHash: 'abcdef0123'),
          ],
      dartPlatformDill: dartDill ?? dill('dart.dill'),
      record: record,
    );

    test(
      'platform dills of the Dart SDK pass and the real hash is recorded',
      () {
        final record = webOf(record: {'sdk': 'local'});
        expect(record['kernel'], {'format': 138, 'sdk_hash': 'abcdef0123'});
        expect(record.containsKey('snapshot_hash'), isFalse);
        expect(record['sdk'], 'local');
      },
    );

    test('a web dill of another kernel format fails, naming both', () {
      final message = failureOf(
        () => webOf(webDills: [dill('dart2js.dill', format: 140)]),
      );
      expect(message, contains('does not match itself for web'));
      expect(message, contains('//label:dart2js.dill'));
      expect(message, contains('//label:dart.dill'));
      expect(message, contains('kernel format 140 vs 138'));
    });

    test('a web dill of another Dart revision fails', () {
      final message = failureOf(
        () => webOf(
          webDills: [dill('dart2js.dill', sdkHash: 'abcdef0123')],
          dartDill: dill('dart.dill', sdkHash: '9999999999'),
        ),
      );
      expect(message, contains('SDK hash abcdef0123 vs 9999999999'));
    });

    test(
      'web dills of different Dart revisions fail even beside a disabled hash',
      () {
        final message = failureOf(
          () => webOf(
            webDills: [
              dill('dart2js.dill', sdkHash: 'abcdef0123'),
              dill('dart2wasm.dill', sdkHash: '0123456789'),
            ],
          ),
        );
        expect(message, contains('//label:dart2wasm.dill'));
        expect(message, contains('SDK hash 0123456789 vs abcdef0123'));
      },
    );

    test('the command line takes any number of dills', () {
      final dartDill = dill('d.dill');
      final first = dill('a.dill', sdkHash: 'abcdef0123');
      final second = dill('b.dill', sdkHash: 'abcdef0123');
      final recordIn = File('${dir.path}/in.json')
        ..writeAsStringSync('{"sdk": "local"}');
      final out = '${dir.path}/out.json';
      final code = run([
        '--mode=web',
        '--web-platform-dill=${first.path}',
        '--web-platform-dill-label=${first.label}',
        '--web-platform-dill=${second.path}',
        '--web-platform-dill-label=${second.label}',
        '--dart-platform-dill=${dartDill.path}',
        '--dart-platform-dill-label=${dartDill.label}',
        '--record-in=${recordIn.path}',
        '--record-out=$out',
      ]);
      expect(code, 0);
      final record = jsonDecode(File(out).readAsStringSync()) as Map;
      expect(record['kernel'], {'format': 138, 'sdk_hash': 'abcdef0123'});
    });
  });
}
