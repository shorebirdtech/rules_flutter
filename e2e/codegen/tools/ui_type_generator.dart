/// Generator that resolves the `dart:ui` types of a Flutter library's fields.
///
/// A `package:build` Builder behind rules_dart's shim runner. For each class
/// field it writes the element and library its type resolves to. A type that
/// does not resolve (as `Color` does not when the analysis has no `dart:ui`)
/// throws, so the build fails rather than writing a placeholder.
library;

import 'package:analyzer/dart/element/type.dart';
import 'package:build/build.dart';
import 'package:rules_dart_ext/worker_entry.dart';

Future<void> main(List<String> args) => shimMain(args, (_) => _UiTypeBuilder());

class _UiTypeBuilder implements Builder {
  // The shim takes the outputs from the rule's declared ones.
  @override
  Map<String, List<String>> get buildExtensions => const {
    '.dart': ['.g.dart'],
  };

  @override
  Future<void> build(BuildStep buildStep) async {
    final library = await buildStep.inputLibrary;
    final entries = <String>[];
    for (final class_ in library.classes) {
      for (final field in class_.fields) {
        final type = field.type;
        final element = type.element;
        if (type is InvalidType || element == null) {
          throw StateError(
            '${class_.displayName}.${field.displayName} has type '
            '"${type.getDisplayString()}", which did not resolve: the '
            'analysis of this action has no dart:ui.',
          );
        }
        final origin = element.library?.uri;
        entries.add(
          "  '${class_.displayName}.${field.displayName}': "
          "'${element.displayName} from $origin',",
        );
      }
    }
    final fileName = buildStep.inputId.pathSegments.last;
    await buildStep.writeAsString(
      buildStep.allowedOutputs.single,
      [
        '// GENERATED CODE - DO NOT MODIFY BY HAND',
        '',
        "part of '$fileName';",
        '',
        '/// The element and library each field type resolved to.',
        'const resolvedFieldTypes = <String, String>{',
        ...entries,
        '};',
        '',
      ].join('\n'),
    );
  }
}
