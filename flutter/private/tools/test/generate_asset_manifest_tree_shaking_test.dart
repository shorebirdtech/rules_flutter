// Tagged `runfiles`: the harness finds the tool and its stand-ins through
// `package:runfiles`, which only Bazel supplies.
@Tags(['runfiles'])
library;

import 'package:test/test.dart';

import 'tree_shaking_harness.dart';

void main() {
  // A font file is stored as the text of its own path, and the stand-in
  // `font-subset` writes `subset(<that text>): <code points kept>`.

  test('an icon font is subset to the code points the program uses', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      constFinderOutput: usesIcons({
        'Icons': [1, 2],
      }),
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 1 2');
  });

  test('a font the program uses no icon of is bundled whole', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
        Family('Text', ['fonts/Text.ttf']),
      ],
      constFinderOutput: usesIcons({
        'Icons': [1],
      }),
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/Text.ttf'), 'fonts/Text.ttf');
  });

  test('each family is subset to its own code points', () async {
    final run = await runTool(
      families: [
        Family('First', ['fonts/First.ttf']),
        Family('Second', ['fonts/Second.ttf']),
      ],
      constFinderOutput: usesIcons({
        'First': [1],
        'Second': [2],
      }),
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(run.read('fonts/First.ttf'), 'subset(fonts/First.ttf): 1');
    expect(run.read('fonts/Second.ttf'), 'subset(fonts/Second.ttf): 2');
  });

  test('each family is subset to its own code points whatever the order '
      'of the manifest, when one path ends with the other', () async {
    final families = [
      Family('Packaged', ['packages/p/fonts/Icons.ttf']),
      Family('Plain', ['fonts/Icons.ttf']),
    ];
    final run = await runTool(
      families: families,
      constFinderOutput: usesIcons({
        'Packaged': [1],
        'Plain': [2],
      }),
    );

    expect(run.exitCode, 0, reason: run.stderrText);
    expect(
      run.read('packages/p/fonts/Icons.ttf'),
      'subset(packages/p/fonts/Icons.ttf): 1',
    );
    expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 2');
  });

  group('a font is subset with the code points of its own family', () {
    // flutter_tools finds the font of a family by its exact path in the
    // bundle. Whatever two paths a bundle holds, a font never takes another
    // family's icons, however the paths relate. The cases are the relations a
    // suffix match gets wrong.
    final cases = <String, List<Family>>{
      // `packages/p/fonts/Icons.ttf` ends with `fonts/Icons.ttf`.
      'one path ends with the other': [
        Family('Plain', ['fonts/Icons.ttf']),
        Family('Packaged', ['packages/p/fonts/Icons.ttf']),
      ],
      // `fonts/MyIcons.ttf` ends with `Icons.ttf`, with no directory between.
      'one name ends with the other': [
        Family('Short', ['Icons.ttf']),
        Family('Long', ['fonts/MyIcons.ttf']),
      ],
    };
    for (final entry in cases.entries) {
      test(entry.key, () async {
        final families = entry.value;
        final run = await runTool(
          families: families,
          constFinderOutput: usesIcons({
            for (final (i, family) in families.indexed) family.name: [i + 1],
          }),
        );

        expect(run.exitCode, 0, reason: run.stderrText);
        for (final (i, family) in families.indexed) {
          final path = family.assets.single;
          expect(run.read(path), 'subset($path): ${i + 1}');
        }
      });
    }
  });

  test('an icon family with several font files fails the build', () async {
    // flutter_tools: "This tool cannot process icon fonts with multiple fonts
    // in a single family." Subsetting the first and shipping the rest whole
    // would leave the bundle holding icons the program was said not to use.
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons-Regular.ttf', 'fonts/Icons-Bold.ttf']),
      ],
      constFinderOutput: usesIcons({
        'Icons': [1],
      }),
    );

    expect(run.exitCode, isNot(0));
  });

  test('a const_finder that fails fails the build', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      constFinderOutput: usesIcons({
        'Icons': [1],
      }),
      constFinderExit: 1,
    );

    expect(run.exitCode, isNot(0));
  });

  test('a font-subset that fails fails the build', () async {
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      constFinderOutput: usesIcons({
        'Icons': [1],
      }),
      contents: {'fonts/Icons.ttf': 'unsubsettable'},
    );

    expect(run.exitCode, isNot(0));
  });

  test('an IconData that is not constant fails the build', () async {
    // flutter_tools: "Avoid non-constant invocations of IconData or try to
    // build again with --no-tree-shake-icons." Which icons such a program
    // uses is unknown, so no subset of the font is safe, and the full font
    // is not what the program was asked to ship.
    final run = await runTool(
      families: [
        Family('Icons', ['fonts/Icons.ttf']),
      ],
      constFinderOutput: {
        'constantInstances': <Object?>[],
        'nonConstantLocations': [
          {'file': 'lib/main.dart', 'line': 3, 'column': 5},
        ],
      },
    );

    expect(run.exitCode, isNot(0));
  });

  group('from recorded uses (Flutter 3.50 on)', () {
    test(
      'an icon font is subset to the code points the program uses',
      () async {
        final run = await runTool(
          families: [
            Family('Icons', ['fonts/Icons.ttf']),
          ],
          recordedUses: recordsIcons({
            'Icons': [1, 2],
          }),
        );

        expect(run.exitCode, 0, reason: run.stderrText);
        expect(run.read('fonts/Icons.ttf'), 'subset(fonts/Icons.ttf): 1 2');
      },
    );

    test('an IconData that is not constant fails the build', () async {
      final run = await runTool(
        families: [
          Family('Icons', ['fonts/Icons.ttf']),
        ],
        recordedUses: recordsIcons({
          'Icons': [1],
        }, nonConstant: true),
      );

      expect(run.exitCode, isNot(0));
    });

    test('a malformed recording fails the build', () async {
      final run = await runTool(
        families: [
          Family('Icons', ['fonts/Icons.ttf']),
        ],
        recordedUses: {'uses': 'not a recording'},
      );

      expect(run.exitCode, isNot(0));
    });
  });
}
