import 'dart:io';

import 'package:flutter_bazel_dev_tool/android_sdk.dart';
import 'package:flutter_bazel_dev_tool/dev_tool_exception.dart';
import 'package:test/test.dart';

const _outputBase = '/ob';
const _executionRoot = '/ob/execroot/_main';
const _info = 'output_base: $_outputBase\nexecution_root: $_executionRoot\n';

/// The hermetic SDK's answer: adb a source file of the platform's repository,
/// aapt2 a built `sh_binary`.
const _cquery =
    '@@hermetic_android_toolchains++android+androidsdk_darwin//:aapt2_binary '
    'bazel-out/darwin_arm64-fastbuild/bin/external/'
    'hermetic_android_toolchains++android+androidsdk_darwin/aapt2_binary\n'
    '@@hermetic_android_toolchains++android+androidsdk_darwin//:platform-tools/darwin/adb '
    'external/hermetic_android_toolchains++android+androidsdk_darwin/'
    'platform-tools/darwin/adb\n';

/// A bazel that answers each command from [answers], keyed by its first
/// argument, and records what it was asked.
class _FakeBazel {
  final Map<String, ProcessResult> answers;
  final calls = <List<String>>[];

  _FakeBazel(this.answers);

  Future<ProcessResult> run(
    List<String> args, {
    required String workingDirectory,
  }) async {
    calls.add(args);
    return answers[args.first] ?? ProcessResult(0, 0, '', '');
  }

  List<String> get commands => [for (final c in calls) c.first];
}

ProcessResult _ok(String stdout) => ProcessResult(0, 0, stdout, '');

void main() {
  group('WorkspaceAndroidSdk', () {
    test(
      'a workspace with no SDK is asked one query and builds nothing',
      () async {
        final bazel = _FakeBazel({'query': _ok('')});
        final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
        expect(await sdk.find(), isNull);
        expect(bazel.commands, ['query']);
        await expectLater(
          sdk.require(),
          throwsA(
            isA<DevToolException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('this workspace has no Android SDK'),
                contains('hermetic_android_toolchains'),
                contains('ANDROID_HOME'),
              ),
            ),
          ),
        );
      },
    );

    test('builds adb and aapt2 for the host, and finds them', () async {
      final bazel = _FakeBazel({
        'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
        'cquery': _ok(_cquery),
        'info': _ok(_info),
      });
      final sdk = WorkspaceAndroidSdk(
        workspace: '/ws',
        runBazel: bazel.run,
        userFlags: ['--config=ci'],
      );
      final tools = (await sdk.find())!;
      expect(
        tools.adb,
        '$_outputBase/external/'
        'hermetic_android_toolchains++android+androidsdk_darwin/'
        'platform-tools/darwin/adb',
      );
      expect(
        tools.aapt2,
        '$_executionRoot/bazel-out/darwin_arm64-fastbuild/bin/external/'
        'hermetic_android_toolchains++android+androidsdk_darwin/aapt2_binary',
      );
      expect(bazel.commands, ['query', 'build', 'cquery', 'info']);
      final build = bazel.calls[1];
      expect(build, containsAll(androidSdkToolLabels));
      expect(build, containsAll(['--config=ci', ...androidSdkToolFlags]));
      // The cquery is in the build's configuration, so it reads the files
      // the build made.
      expect(
        bazel.calls[2],
        containsAll(['--config=ci', ...androidSdkToolFlags]),
      );
    });

    test('asks once per run', () async {
      final bazel = _FakeBazel({
        'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
        'cquery': _ok(_cquery),
        'info': _ok(_info),
      });
      final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
      await sdk.find();
      await sdk.require();
      expect(bazel.commands, ['query', 'build', 'cquery', 'info']);
    });

    test('a failed build names the command and what bazel said', () async {
      final bazel = _FakeBazel({
        'query': _ok('@androidsdk//:aapt2\n@androidsdk//:adb\n'),
        'build': ProcessResult(0, 1, '', 'ERROR: licence not accepted'),
      });
      final sdk = WorkspaceAndroidSdk(workspace: '/ws', runBazel: bazel.run);
      await expectLater(
        sdk.find(),
        throwsA(
          isA<DevToolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains("build the Android SDK's adb and aapt2"),
              contains('cd /ws && bazel build'),
              contains('ERROR: licence not accepted'),
            ),
          ),
        ),
      );
    });
  });

  group('androidSdkToolsFrom', () {
    test('reads an installed SDK, whose aapt2 is a built runner', () {
      final tools = androidSdkToolsFrom(
        cquery:
            '@@rules_android++android_sdk_repository_extension+androidsdk//:aapt2_binary '
            'bazel-out/darwin_arm64-fastbuild/bin/external/'
            'rules_android++android_sdk_repository_extension+androidsdk/aapt2_binary\n'
            '@@rules_android++android_sdk_repository_extension+androidsdk//:platform-tools/adb '
            'external/rules_android++android_sdk_repository_extension+androidsdk/'
            'platform-tools/adb\n',
        info: _info,
      );
      expect(tools.adb, endsWith('androidsdk/platform-tools/adb'));
      expect(tools.adb, startsWith('$_outputBase/external/'));
      expect(tools.aapt2, startsWith('$_executionRoot/bazel-out/'));
    });

    test('reads Windows executables', () {
      final tools = androidSdkToolsFrom(
        cquery:
            '@@sdk//:build-tools/35.0.0/aapt2.exe external/sdk/build-tools/35.0.0/aapt2.exe\n'
            '@@sdk//:platform-tools/adb.exe external/sdk/platform-tools/adb.exe\n',
        info: _info,
      );
      expect(tools.adb, endsWith('adb.exe'));
      expect(tools.aapt2, endsWith('aapt2.exe'));
    });

    test('refuses an answer missing a tool', () {
      expect(
        () => androidSdkToolsFrom(
          cquery:
              '@@sdk//:platform-tools/adb external/sdk/platform-tools/adb\n',
          info: _info,
        ),
        throwsA(isA<DevToolException>()),
      );
    });
  });
}
