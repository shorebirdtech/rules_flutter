/// Per-file generator for the `dep_lib` package: emits a STANDALONE library
/// (not a `part of`) that the hand-written sibling imports.
///
/// A `package:build` Builder behind rules_dart's shim runner.
library;

import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) =>
    shimMain(args, (_) => _CatalogBuilder());

class _CatalogBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final source = await buildStep.readAsString(buildStep.inputId);
    // Discover the input's field names. Editing the fields (a codegen INPUT
    // change) changes this generated standalone library, observable on reload.
    final fields = [
      for (final m in RegExp(r'final\s+\w+\s+(\w+);').allMatches(source))
        m.group(1)!,
    ];

    // A real library (top-level const list), not a `part of`, imported by the
    // hand-written sibling.
    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln()
      ..writeln('const List<String> catalogFields = [')
      ..writeAll(fields.map((f) => "  '$f',\n"))
      ..writeln('];');

    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      buffer.toString(),
    );
  }
}
