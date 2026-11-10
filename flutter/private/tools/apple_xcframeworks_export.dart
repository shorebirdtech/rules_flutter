/// The program behind `bazel run` of `flutter_ios_xcframeworks` and
/// `flutter_macos_xcframeworks`: writes the xcframeworks where `flutter build
/// ios-framework` and `macos-framework` write them.
///
/// The build made one mode, the configuration's, as `<Mode>/` beside the
/// files that go above the modes (the plugin registrant's sources, the LLDB
/// files of a debug build). This writes `<Mode>/` in place of the one an
/// earlier run wrote, and those files beside it, under
/// `build/<platform>/framework/` in the target's package, or `--output`. A run
/// per mode fills `Debug/`, `Profile/` and `Release/`.
///
/// Environment:
///   RULES_FLUTTER_XCFRAMEWORKS_CONFIG  runfiles path of the JSON config the
///                                      rule wrote.
///   BUILD_WORKSPACE_DIRECTORY, BUILD_WORKING_DIRECTORY  set by `bazel run`.
///
/// Flags (after `--`):
///   --output=<dir>  where to write, relative to where `bazel run` ran.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'apple_frameworks.dart' show copyBundle;
import 'assemble_directory.dart' show copyFile;

const configEnv = 'RULES_FLUTTER_XCFRAMEWORKS_CONFIG';

/// The build modes `flutter build <platform>-framework` writes, by directory.
const modes = ['Debug', 'Profile', 'Release'];

/// What the rule told the program.
class ExportConfig {
  ExportConfig({
    required this.tree,
    required this.package,
    required this.platform,
    required this.mode,
  });

  /// The built tree: `<Mode>/` and the files above it.
  final String tree;

  /// The target's package, which the default output is under.
  final String package;

  /// `ios` or `macos`.
  final String platform;

  /// `Debug`, `Profile` or `Release`.
  final String mode;
}

/// Where to write: `--output` from [workingDirectory], or
/// `build/<platform>/framework` in [config]'s package of [workspace].
String outputDirectory(
  ExportConfig config,
  List<String> args, {
  required String workspace,
  required String workingDirectory,
}) {
  for (final arg in args) {
    if (arg.startsWith('--output=')) {
      final output = arg.substring('--output='.length);
      if (output.isEmpty) throw const FormatException('--output is empty');
      return output.startsWith('/') ? output : '$workingDirectory/$output';
    }
    throw FormatException('unexpected argument: $arg');
  }
  final package = config.package.isEmpty ? '' : '${config.package}/';
  return '$workspace/${package}build/${config.platform}/framework';
}

/// Writes [config]'s tree into [output]: its mode's directory replaced, the
/// files above it beside. Returns the lines to print.
List<String> exportTree(ExportConfig config, String output) {
  final tree = Directory(config.tree);
  final destination = Directory(output)..createSync(recursive: true);
  final mode = Directory('${destination.path}/${config.mode}');
  if (mode.existsSync()) mode.deleteSync(recursive: true);
  for (final entry in tree.listSync()) {
    final name = entry.path.split('/').last;
    if (modes.contains(name)) {
      copyBundle(
        Directory(entry.path),
        Directory('${destination.path}/$name'),
        link: true,
      );
    } else {
      copyFile(File(entry.path), '${destination.path}/$name');
    }
  }
  final lines = ['Frameworks written to ${mode.path}.'];
  final others = [
    for (final m in modes)
      if (m != config.mode && Directory('${destination.path}/$m').existsSync())
        m,
  ];
  if (others.isNotEmpty) {
    lines.add(
      '${others.join(' and ')} ${others.length == 1 ? 'is' : 'are'} from an '
      'earlier run: build every mode from the same sources before shipping '
      '(mixing modes crashes at launch).',
    );
  }
  if (File('${destination.path}/GeneratedPluginRegistrant.m').existsSync()) {
    lines.add(
      'Link FlutterPluginRegistrant.xcframework, or add '
      'GeneratedPluginRegistrant.h and .m to your project.',
    );
  }
  if (File('${destination.path}/GeneratedPluginRegistrant.swift')
      .existsSync()) {
    lines.add('Copy GeneratedPluginRegistrant.swift into your project.');
  }
  return lines;
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final configPath = Platform.environment[configEnv];
  if (configPath == null) {
    stderr.writeln('$configEnv is not set: run this with `bazel run`.');
    exit(2);
  }
  final json = jsonDecode(
    File(runfiles.rlocation(configPath)).readAsStringSync(),
  ) as Map<String, Object?>;
  final config = ExportConfig(
    tree: runfiles.rlocation(json['tree']! as String),
    package: json['package']! as String,
    platform: json['platform']! as String,
    mode: json['mode']! as String,
  );
  final workspace = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspace == null) {
    stderr.writeln(
      'BUILD_WORKSPACE_DIRECTORY is not set: run this with `bazel run`.',
    );
    exit(2);
  }
  final String output;
  try {
    output = outputDirectory(
      config,
      args,
      workspace: workspace,
      workingDirectory:
          Platform.environment['BUILD_WORKING_DIRECTORY'] ?? workspace,
    );
  } on FormatException catch (e) {
    stderr.writeln(
      '${e.message}\nusage: bazel run <target> [-- --output=<dir>]',
    );
    exit(64);
  }
  exportTree(config, output).forEach(stdout.writeln);
}
