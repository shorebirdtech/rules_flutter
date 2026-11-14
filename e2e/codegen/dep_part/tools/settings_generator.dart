/// Per-file generator for the `dep_part` package: emits a `part of` extension
/// with a `toJson()` for the first class in the input.
///
/// A `package:build` Builder behind rules_dart's shim runner.
library;

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) =>
    shimMain(args, (_) => _SettingsBuilder());

class _SettingsBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    final className = RegExp(r'class\s+(\w+)').firstMatch(source)!.group(1)!;
    final fields = [
      for (final m in RegExp(r'final\s+(\w+)\s+(\w+);').allMatches(source))
        m.group(2)!,
    ];

    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln()
      ..writeln("part of '${buildStep.inputId.pathSegments.last}';")
      ..writeln()
      ..writeln('extension ${className}Json on $className {')
      ..writeln('  Map<String, dynamic> toJson() => {');
    for (final f in fields) {
      buffer.writeln("        '$f': $f,");
    }
    buffer
      ..writeln('      };')
      ..writeln('}');

    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      buffer.toString(),
    );
  }
}
