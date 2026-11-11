/// Per-file code generator producing `toJson()` extensions.
///
/// A second generator shape (alongside simple_generator's toDebugString) so the
/// e2e covers more than one `dart_codegen` output format. Emits a `part of`
/// file, which is what the Flutter app (lib/user.dart) consumes, exercising the
/// kernel compile's co-location of a generated part with its source sibling.
library;

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, (_) => _JsonBuilder());

class _JsonBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    final classPattern = RegExp(r'class\s+(\w+)');
    final fieldPattern = RegExp(r'final\s+(\w+)\s+(\w+);');

    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln()
      ..writeln("part of '${buildStep.inputId.pathSegments.last}';")
      ..writeln();

    for (final classMatch in classPattern.allMatches(source)) {
      final className = classMatch.group(1)!;
      final classStart = classMatch.start;
      final nextClass = classPattern.firstMatch(
        source.substring(classStart + 1),
      );
      final classEnd = nextClass != null
          ? classStart + 1 + nextClass.start
          : source.length;
      final classBody = source.substring(classStart, classEnd);

      final fields = <(String, String)>[
        for (final m in fieldPattern.allMatches(classBody))
          (m.group(1)!, m.group(2)!),
      ];

      buffer
        ..writeln('extension ${className}Json on $className {')
        ..writeln('  Map<String, dynamic> toJson() => {');
      for (final (_, name) in fields) {
        buffer.writeln("        '$name': $name,");
      }
      buffer
        ..writeln('      };')
        ..writeln('}')
        ..writeln();
    }

    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      buffer.toString(),
    );
  }
}
