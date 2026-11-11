/// Aggregate code generator for the `dart_aggregate_codegen` rule.
///
/// A `package:build` Builder behind rules_dart's shim runner. The rule stages
/// every source beside the primary one as an input asset of the same package,
/// so the Builder finds them with `findAssets`. It reads them all, finds every
/// class definition across them, and generates a single registry file listing
/// every model class.
library;

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) =>
    shimMain(args, (_) => _AggregateBuilder());

class _AggregateBuilder implements Builder {
  // The shim takes the output from the rule's declared one.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final classPattern = RegExp(r'^class\s+(\w+)', multiLine: true);
    final allClasses = <String>[];
    var sourceCount = 0;

    await for (final id in buildStep.findAssets(Glob('lib/**.dart'))) {
      if (id.package != buildStep.inputId.package) continue;
      sourceCount++;
      final source = await buildStep.readAsString(id);
      for (final match in classPattern.allMatches(source)) {
        allClasses.add(match.group(1)!);
      }
    }

    allClasses.sort();

    final buffer = StringBuffer()
      ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
      ..writeln(
        '// Aggregate registry generated from '
        '$sourceCount source file(s).',
      )
      ..writeln()
      ..writeln('/// All model classes discovered by the aggregate generator.')
      ..writeln('const List<String> registeredModels = [');
    for (final cls in allClasses) {
      buffer.writeln("  '$cls',");
    }
    buffer
      ..writeln('];')
      ..writeln()
      ..writeln('/// Number of registered model classes.')
      ..writeln('const int modelCount = ${allClasses.length};')
      ..writeln();

    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      buffer.toString(),
    );
  }
}
