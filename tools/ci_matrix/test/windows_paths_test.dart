/// The Windows E2E job builds Android apps in a tree short enough for aapt2.
///
/// aapt2 is not long-path aware: it fails with "file not found" on any path of
/// 260 characters or more, whatever `LongPathsEnabled` says. rules_jvm_external
/// unzips each AAR into
/// `bazel-out/<config>/bin/external/<repo>/_aar/unzipped/resources/...`, and the
/// longest resource of `e2e/plugin_example` is [_longestExecrootPath] characters
/// below the execution root, so the execution root itself may take only what is
/// left. It is the output base plus `/execroot/_main/`.
///
/// setup-bazel writes `startup --output_base=...` to the user's `.bazelrc`
/// (`D:/_bazel` on Windows, beside the workspace), and a startup option there
/// wins over `--output_user_root` on the command line, so that flag, which the
/// job used to pass, changed nothing. The job names the output base itself,
/// through setup-bazel's `output-base` input.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

/// The longest path under an execution root that aapt2 reads in
/// `e2e/plugin_example`: rules_jvm_external's unzipped `appcompat` resource
/// `btn_checkbox_unchecked_mtrl_animation_interpolator_1.xml`, measured in the
/// failing build on a Windows VM (docs/TESTING.md, "Windows and MAX_PATH").
const _longestExecrootPath = 233;

/// The longest path aapt2 opens; at 260 it reports "file not found".
const _aapt2Limit = 259;

/// A drive, a colon and one directory: the output base cannot be shorter. The
/// path above leaves 26 characters to the limit before the execution root, and
/// `/execroot/_main/` alone takes 16 of them, so a longer artifact name on a
/// bump would soon fail; the base takes no more than it must.
const _shortestBase = 'D:/b';

void main() {
  final runfiles = Runfiles.create(
    sourceRepository: Platform.environment['RUNFILES_SOURCE_REPO'] ?? '',
  );
  // Comments explain the setting and may name the flag.
  final ci = File(runfiles.rlocation(Platform.environment['CI_WORKFLOW']!))
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n');

  test(
    'no step passes --output_user_root, which a startup output_base beats',
    () {
      expect(ci, isNot(contains('--output_user_root')));
    },
  );

  test('the E2E job sets the output base of Windows to a short path', () {
    // `output-base: ${{ runner.os == 'Windows' && format('{0}/b', ...) || '' }}`
    final input = RegExp(
      r"output-base: \$\{\{[^}]*runner\.os == 'Windows'[^}]*format\('\{0\}(/[^']*)'",
    ).firstMatch(ci);
    expect(
      input,
      isNotNull,
      reason: 'the E2E job gives setup-bazel no output-base for Windows',
    );
    // A drive letter and colon, then the path below it.
    final base = 'D:${input![1]}';
    expect(base.length, lessThanOrEqualTo(_shortestBase.length));
    final execroot = '$base/execroot/_main/'.length;
    expect(
      execroot + _longestExecrootPath,
      lessThanOrEqualTo(_aapt2Limit),
      reason: 'execution root $base/execroot/_main/ is $execroot characters',
    );
  });
}
