/// Runs `generate_asset_manifest.dart` over icon fonts, with a stand-in for
/// each program it calls, and returns what it did.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

/// One font family in the `FontManifest.json` the tool is given.
class Family {
  Family(this.name, this.assets);

  final String name;

  /// Bundle paths of the family's font files.
  final List<String> assets;
}

/// What a run of the tool left behind.
class Run {
  Run(this.exitCode, this.stderrText, this._files);

  final int exitCode;
  final String stderrText;
  final Map<String, String> _files;

  /// What the bundle holds at [path], or null when nothing is there.
  String? read(String path) => _files[path];
}

/// Runs the tool for [families], each font file of which is the text
/// `<its path>` (or [contents]'s entry for the path), with the icons that
/// `constFinderOutput` says the program uses. A font file whose contents say
/// `unsubsettable` makes the stand-in `font-subset` fail; [constFinderExit] is
/// what the stand-in `const_finder` exits with. With [recordedUses] (a
/// `--recorded-uses` file's contents, Flutter 3.50 on) the tool reads the
/// icons from it and runs no const_finder.
Future<Run> runTool({
  required List<Family> families,
  Map<String, Object?> constFinderOutput = const {},
  Map<String, Object?>? recordedUses,
  Map<String, String> contents = const {},
  int constFinderExit = 0,
}) async {
  final runfiles = Runfiles.create();
  String runfile(String path) => runfiles.rlocation(path);

  final work = Directory.systemTemp.createTempSync('tree_shaking_');
  try {
    final sources = Directory('${work.path}/src')..createSync();
    final copies = <String, String>{};
    for (final family in families) {
      for (final asset in family.assets) {
        final source = File('${sources.path}/${asset.replaceAll('/', '_')}')
          ..writeAsStringSync(contents[asset] ?? asset);
        copies[asset] = source.path;
      }
    }

    // `const_finder` is run as `dart <snapshot> --kernel-file ...` and prints
    // what it found as JSON.
    final constFinder = File('${work.path}/const_finder.dart')
      ..writeAsStringSync('''
import 'dart:io';
void main() {
  stdout.write(${jsonEncode(jsonEncode(constFinderOutput))});
  stderr.write('const_finder says no');
  exit($constFinderExit);
}
''');

    final config = File('${work.path}/config.json')
      ..writeAsStringSync(
        jsonEncode({
          'assets': <String, Object?>{},
          'fonts': [
            for (final family in families)
              {
                'family': family.name,
                'fonts': [
                  for (final asset in family.assets) {'asset': asset},
                ],
              },
          ],
          'copies': copies,
          'icon_tree_shaking': {
            'font_subset': runfile(
              '_main/flutter/private/tools/fake_font_subset'
              '${Platform.isWindows ? '.exe' : ''}',
            ),
            if (recordedUses != null)
              'recorded_uses': (File(
                '${work.path}/recorded_uses.json',
              )..writeAsStringSync(jsonEncode(recordedUses))).path
            else ...{
              'dart': Platform.resolvedExecutable,
              'const_finder': constFinder.path,
              'kernel_dill': '${work.path}/app.dill',
            },
          },
        }),
      );

    final bundle = Directory('${work.path}/bundle');
    final result = await Process.run(Platform.resolvedExecutable, [
      runfile('_main/flutter/private/tools/generate_asset_manifest.dart'),
      '--config',
      config.path,
      '--output-dir',
      bundle.path,
    ]);

    // Only the fonts are read back: the rest of a bundle is binary.
    return Run(result.exitCode, '${result.stderr}', {
      for (final asset in copies.keys)
        if (File('${bundle.path}/$asset').existsSync())
          asset: File('${bundle.path}/$asset').readAsStringSync(),
    });
  } finally {
    work.deleteSync(recursive: true);
  }
}

/// A const_finder answer in which the program uses [codePoint] of [family].
Map<String, Object?> usesIcons(Map<String, List<int>> codePointsByFamily) => {
  'constantInstances': [
    for (final entry in codePointsByFamily.entries)
      for (final codePoint in entry.value)
        {'fontFamily': entry.key, 'codePoint': codePoint},
  ],
  'nonConstantLocations': <Object?>[],
};

/// A `--recorded-uses` file in which the program creates an `IconData` of each
/// of [codePointsByFamily]'s code points, as a constant instance does.
/// [nonConstant] adds one whose code point the compiler could not evaluate.
Map<String, Object?> recordsIcons(
  Map<String, List<int>> codePointsByFamily, {
  bool nonConstant = false,
}) {
  final constants = <Map<String, Object?>>[
    {'type': 'non_constant'},
  ];
  int add(Map<String, Object?> constant) {
    constants.add(constant);
    return constants.length - 1;
  }

  final uses = <Map<String, Object?>>[];
  for (final entry in codePointsByFamily.entries) {
    final family = add({'type': 'string', 'value': entry.key});
    for (final codePoint in entry.value) {
      final instance = add({
        'type': 'instance',
        'definition_index': 0,
        'value': {
          'codePoint': add({'type': 'int', 'value': codePoint}),
          'fontFamily': family,
        },
      });
      uses.add({
        'type': 'constant',
        'constant_index': instance,
        'loading_unit_index': 0,
      });
    }
  }
  if (nonConstant) {
    uses.add({
      'type': 'creation',
      'definition_index': 0,
      'loading_unit_index': 0,
      'positional': [0],
      'named': <String, Object?>{},
    });
  }
  return {
    'constants': constants,
    'definitions': [
      {
        'path': [
          {'kind': 'class', 'name': 'IconData'},
        ],
        'uri': 'package:flutter/src/widgets/icon_data.dart',
      },
    ],
    'loading_units': [
      {'name': '1'},
    ],
    'uses': {
      'instances': [
        {'definition_index': 0, 'uses': uses},
      ],
    },
  };
}
