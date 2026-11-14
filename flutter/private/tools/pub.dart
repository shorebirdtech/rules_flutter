/// Runs `dart pub` from the pinned Flutter toolchain against the user's
/// workspace, so `pubspec.lock` is resolved by the SDK that will compile it.
///
/// Bazel consumes `pubspec.lock` but never produces one. Resolving it with a
/// separately installed Flutter — whatever version happens to be on `PATH` —
/// silently changes which versions get pinned, because pub's solver takes the
/// running Dart SDK's version and the Flutter SDK's version as constraints.
/// This program removes that variable: the `dart` it runs is the toolchain's,
/// and `FLUTTER_ROOT` points at a tree assembled from the same Flutter tag.
///
/// It is compiled by `dart compile exe` alone, from this file and
/// `pub_runfiles.dart`, both of which import only the Dart libraries: no Dart
/// tool rules_flutter or rules_dart builds, and so no repository of a pub
/// extension, takes part. It runs while an extension refuses a lock, the state
/// in which its errors tell the user to run it.
library;

import 'dart:io';

import 'pub_runfiles.dart';

/// The runfiles path of the toolchain's `dart`, fixed when this was compiled.
const _dart = String.fromEnvironment('rules_flutter.pub.dart');

/// The runfiles path of `bin/cache/flutter.version.json` inside the assembled
/// FLUTTER_ROOT, fixed when this was compiled.
const _manifest = String.fromEnvironment('rules_flutter.pub.version_manifest');

/// Depth of `bin/cache/flutter.version.json` below the root it anchors.
const _manifestDepth = 3;

/// Entries whose absence means the tree cannot resolve a Flutter app's pubspec.
const _requiredEntries = <String>[
  'packages/flutter/pubspec.yaml',
  'bin/cache/pkg/sky_engine/pubspec.yaml',
];

const _usage =
    'Usage:\n'
    '  bazel run @rules_flutter//flutter/pub -- get\n'
    '  bazel run @rules_flutter//flutter/pub -- upgrade\n'
    '  bazel run @rules_flutter//flutter/pub -- add qr';

Never _fail(String message) {
  stderr.writeln('flutter/pub: $message');
  exit(1);
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    _fail('no pub command given.\n$_usage');
  }

  // `bazel run` sets this to the source tree. pub has to run there rather than
  // in the runfiles tree: `pubspec.lock` is a checked-in file.
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null || workspace.isEmpty) {
    _fail(
      'BUILD_WORKSPACE_DIRECTORY is not set. Use `bazel run`, not the '
      'built binary directly.\n$_usage',
    );
  }

  // Under `--noenable_runfiles` (Windows' default) only a manifest is there,
  // which maps each path to the file's own location.
  final Runfiles runfiles;
  try {
    runfiles = Runfiles.discover(
      Platform.environment,
      Platform.resolvedExecutable,
    );
  } on StateError catch (e) {
    _fail(e.message);
  }
  String locate(String what, String path) {
    final found = runfiles.rlocation(path);
    if (found == null || !File(found).existsSync()) {
      _fail(
        'cannot find $what: its runfile $path resolves to '
        '${found ?? 'nothing'}.',
      );
    }
    return found;
  }

  final dart = locate("the toolchain's dart", _dart);
  final manifest = locate('the Flutter version manifest', _manifest);

  var flutterRoot = File(manifest).absolute.parent;
  for (var i = 1; i < _manifestDepth; i++) {
    flutterRoot = flutterRoot.parent;
  }
  for (final entry in _requiredEntries) {
    if (!File('${flutterRoot.path}/$entry').existsSync()) {
      _fail(
        'the FLUTTER_ROOT assembled at ${flutterRoot.path} has no $entry, '
        'so pub cannot resolve `sdk: flutter` dependencies. The flutter '
        'tag layout may have changed — see '
        'flutter/private/flutter_dev_root_repo.bzl.',
      );
    }
  }

  stderr.writeln(
    'flutter/pub: resolving in $workspace with the pinned '
    'toolchain (FLUTTER_ROOT=${flutterRoot.path})',
  );

  final process = await Process.start(
    dart,
    // `--suppress-analytics` keeps `dart` from recording a telemetry identity
    // and its first-run notice under the HOME of whoever ran `bazel run`.
    ['--suppress-analytics', 'pub', ...args],
    workingDirectory: workspace,
    environment: {'FLUTTER_ROOT': flutterRoot.path},
    mode: ProcessStartMode.inheritStdio,
  );
  final code = await process.exitCode;
  // A process a signal ended reports minus the signal; a shell reports 128
  // plus it.
  exit(code < 0 ? 128 - code : code);
}
