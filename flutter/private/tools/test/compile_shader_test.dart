import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../compile_shader.dart';

void main() {
  group('withoutSksl', () {
    test('drops --sksl and keeps the runtime stages', () {
      expect(
        withoutSksl(['--sksl', '--runtime-stage-metal', '--iplr']),
        ['--runtime-stage-metal', '--iplr'],
      );
    });

    test('has no retry when SkSL is the only stage, as on web', () {
      expect(withoutSksl(['--sksl', '--iplr', '--json']), isNull);
    });

    test('has no retry when SkSL was never asked for, as on iOS', () {
      expect(withoutSksl(['--runtime-stage-metal', '--iplr']), isNull);
    });
  });

  group('compileShader', () {
    late String impellerc;

    // A stand-in impellerc that, like the real one on an Impeller-only
    // shader, fails whenever it is asked for SkSL: a compiled Dart program, as
    // a script would not start on every OS.
    setUp(() {
      impellerc = Runfiles.create().rlocation(
        '_main/flutter/private/tools/fake_impellerc'
        '${Platform.isWindows ? '.exe' : ''}',
      );
    });

    Future<(int, String)> run(List<String> flags, {bool strict = false}) async {
      final err = StringBuffer();
      final code = await compileShader([
        '--impellerc',
        impellerc,
        '--shader',
        'shaders/glass.frag',
        if (strict) '--require-sksl',
        '--',
        ...flags,
      ], err);
      return (code, err.toString());
    }

    test('falls back to the Impeller stages with a warning', () async {
      final (code, err) = await run(['--sksl', '--runtime-stage-metal']);
      expect(code, 0);
      expect(err, contains('warning: Shader shaders/glass.frag'));
      expect(err, contains('index expression must be constant'));
    });

    test('fails when SkSL is required', () async {
      final (code, err) = await run([
        '--sksl',
        '--runtime-stage-metal',
      ], strict: true);
      expect(code, isNot(0));
      expect(err, contains('require_sksl_shaders'));
    });

    test('fails when SkSL is the only stage', () async {
      final (code, err) = await run(['--sksl', '--json']);
      expect(code, isNot(0));
      expect(err, contains('index expression must be constant'));
      expect(err, isNot(contains('warning')));
    });

    test('says nothing when the first compile succeeds', () async {
      final (code, err) = await run(['--runtime-stage-metal']);
      expect(code, 0);
      expect(err, isEmpty);
    });
  });
}
