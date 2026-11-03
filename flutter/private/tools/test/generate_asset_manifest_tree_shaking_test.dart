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
}
