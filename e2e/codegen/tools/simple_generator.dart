/// Per-file code generator for the `dart_codegen` rule.
///
/// A `package:build` Builder behind rules_dart's shim runner. Reads a `.dart`
/// source file, finds class definitions and their fields, and generates a
/// companion `part of` file with `toDebugString()` extensions.
library;

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, (_) => _SimpleBuilder());

class _SimpleBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    final fileName = buildStep.inputId.pathSegments.last;
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      _generateForSource(source, fileName),
    );
  }
}

/// Parse classes and fields from [source] and return generated code.
String _generateForSource(String source, String fileName) {
  final classPattern = RegExp(r'^class\s+(\w+)', multiLine: true);
  final fieldPattern = RegExp(r'final\s+\w+\s+(\w+);');

  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln()
    ..writeln("part of '$fileName';")
    ..writeln();

  for (final classMatch in classPattern.allMatches(source)) {
    final className = classMatch.group(1)!;

    // Extract the body between this class and the next (or end of file).
    final classStart = classMatch.start;
    final nextClass = classPattern.firstMatch(source.substring(classStart + 1));
    final classEnd = nextClass != null
        ? classStart + 1 + nextClass.start
        : source.length;
    final classBody = source.substring(classStart, classEnd);

    final fields = <String>[
      for (final m in fieldPattern.allMatches(classBody)) m.group(1)!,
    ];

    buffer
      ..writeln('extension ${className}Debug on $className {')
      ..writeln('  String toDebugString() {');
    if (fields.isEmpty) {
      buffer.writeln("    return '$className()';");
    } else {
      final parts = fields.map((f) => '$f: \$$f').join(', ');
      buffer.writeln("    return '$className($parts)';");
    }
    buffer
      ..writeln('  }')
      ..writeln('}')
      ..writeln();
  }

  return buffer.toString();
}
