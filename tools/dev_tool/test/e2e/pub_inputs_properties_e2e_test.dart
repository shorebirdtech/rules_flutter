/// Pub inputs rules_flutter cannot honour must not become a quiet, degraded
/// build. Each test here states one property.
///
/// Three properties, each quantified over several inputs so that a different
/// bug breaking the same promise fails too:
///
///  1. **Refuse what cannot be honoured, loudly.** A pub input rules_flutter
///     cannot build exactly as `flutter` would (an asset transformer it does
///     not run, a file name it cannot put in a BUILD file, a lock entry it has
///     no repository for) fails with a message that names the package and the
///     input, while the repository is fetched or, for a lock entry nothing
///     has to use, when something depends on it. It never yields a green
///     build of something else. Where rules_flutter can honour the input
///     instead, that is as good: every test accepts "builds, and the input is
///     there" as well.
///  2. **A repository rule re-runs when anything it read, or looked for,
///     changes.** Adding an overlay file the rule looked for and did not find
///     is a change.
///  3. **Running pub through Bazel leaves the user's HOME alone.**
///
/// The workspaces are generated (`pub_inputs_fixture.dart`): a real
/// `flutter.pub()` hub over packages served from `file://`.
@Tags(['e2e'])
library;

import 'package:test/test.dart';

import 'pub_inputs_fixture.dart';

/// Fail unless [result] is rules_flutter refusing [package] during the fetch
/// of its repository, with [mentions] in the message.
///
/// [what] is the input, for the failure message.
void expectRefused(
  BazelResult result, {
  required String package,
  required String what,
  required List<String> mentions,
}) {
  expect(
    result.succeeded,
    isFalse,
    reason: 'rules_flutter built @pubhub__$package from $what without a word',
  );
  expect(
    refusedAtFetch(result),
    isTrue,
    reason:
        'the failure should be rules_flutter refusing $what while fetching '
        '$package, not something Bazel hit afterwards:\n$result',
  );
  expect(
    namesPackage(result.output, package),
    isTrue,
    reason: 'the refusal of $what does not name the package $package:\n$result',
  );
  final lower = result.output.toLowerCase();
  for (final mention in mentions) {
    expect(
      lower,
      contains(mention.toLowerCase()),
      reason: 'the refusal of $what does not say "$mention":\n$result',
    );
  }
}

String _pubspec(String name, String body) =>
    'name: $name\nversion: 1.0.0\nenvironment:\n  sdk: ^3.0.0\n$body';

void main() {
  group('a file name in a package', () {
    // Names a pubspec may list and a filesystem may hold. Space, `$`, braces
    // and non-ASCII are fine for Bazel and are in the control test.
    final odd = {
      'quote': ('quote"name.txt', 'name.txt'),
      'backslash': (r'back\slash.txt', 'slash.txt'),
      'colon': ('colon:name.txt', 'name.txt'),
      // Starlark in the name. Evaluating it makes `fail` print INJE+CTED.
      'injection': ('inj"+fail("INJE"+"CTED")+".txt', '.txt'),
    };
    late PubInputsWorkspace ws;

    String assetPubspec(String name, String path) =>
        _pubspec(name, 'flutter:\n  assets:\n    - assets/$path\n');
    String fontPubspec(String name, String path) => _pubspec(
      name,
      'flutter:\n  fonts:\n    - family: F\n      fonts:\n        - asset: fonts/$path\n',
    );

    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in odd.entries) ...[
            HostedPackage(
              'asset_${entry.key}',
              pubspec: assetPubspec('asset_${entry.key}', entry.value.$1),
              files: {'assets/${entry.value.$1}': 'x'},
            ),
            HostedPackage(
              'font_${entry.key}',
              pubspec: fontPubspec('font_${entry.key}', entry.value.$1),
              files: {'fonts/${entry.value.$1}': 'x'},
            ),
          ],
        ],
      ).materialize();
    });

    /// The name is data. It is written into a generated BUILD file, so a
    /// name that is not a valid string there breaks the file, and one that is
    /// Starlark runs as the spoke's own code. Either the package builds with
    /// the file under the name it has, or the fetch refuses it, naming the
    /// package and the file. A syntax error from a BUILD file nobody wrote, or
    /// a label error from the generated one, is neither.
    for (final kind in ['asset', 'font']) {
      for (final entry in odd.entries) {
        test(
          '$kind named ${entry.key} builds or is refused naming package and file',
          () async {
            final package = '${kind}_${entry.key}';
            final fragment = entry.value.$2;
            final result = await ws.loadSpoke(package);
            expect(
              result.output,
              isNot(contains('INJECTED')),
              reason: 'a file name ran as code in the spoke:\n$result',
            );
            if (result.succeeded) {
              final build = await ws.bazel([
                'query',
                '--output=build',
                '@pubhub__$package//:$package',
              ]);
              expect(
                build.output,
                contains(fragment),
                reason:
                    'the package loads but its BUILD has lost the file:\n$build',
              );
              return;
            }
            expectRefused(
              result,
              package: package,
              what: 'a $kind file named ${entry.value.$1}',
              mentions: [fragment],
            );
          },
        );
      }
    }
  });

  group('an Android namespace in a package', () {
    // The namespace is written into the plugin's generated Android BUILD file
    // (the library's `custom_package` and a genrule that emits BuildConfig),
    // so it must be a dotted Java name, not text that ends a string.
    final hostile = {
      'gradle': (
        'android/build.gradle',
        "android {\n    namespace = 'dev.x\"+fail(\"INJE\"+\"CTED\")+\"'\n}\n",
      ),
      'manifest': (
        'android/src/main/AndroidManifest.xml',
        '<manifest package=\'dev.x"+fail("INJE"+"CTED")+"\'>\n</manifest>\n',
      ),
    };
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          for (final entry in hostile.entries)
            androidPlugin('ns_${entry.key}', {entry.value.$1: entry.value.$2}),
        ],
      ).materialize();
    });

    for (final key in hostile.keys) {
      test('from the $key is refused naming the package, never run', () async {
        final result = await ws.loadSpoke('ns_$key');
        expect(
          result.output,
          isNot(contains('INJECTED')),
          reason: 'a namespace ran as code in the spoke:\n$result',
        );
        expectRefused(
          result,
          package: 'ns_$key',
          what: 'an Android namespace that is not a Java package name',
          mentions: ['namespace'],
        );
      });
    }
  });

  group('an asset with transformers', () {
    late PubInputsWorkspace ws;
    setUpAll(() async {
      ws = await PubInputsFixture(
        hosted: [
          HostedPackage(
            'transformed',
            pubspec: _pubspec(
              'transformed',
              'flutter:\n'
                  '  assets:\n'
                  '    - path: assets/data.txt\n'
                  '      transformers:\n'
                  '        - package: some_transformer\n',
            ),
            files: {'assets/data.txt': 'x'},
          ),
        ],
      ).materialize();
    });

    /// `transformers:` on an asset runs a program over the file before it is
    /// bundled. rules_flutter does not run it, so building without it ships
    /// the untransformed file under the transformed file's name.
    test('is refused naming the package and the key', () async {
      final result = await ws.loadSpoke('transformed');
      expectRefused(
        result,
        package: 'transformed',
        what: 'an asset with transformers',
        mentions: ['transformers'],
      );
    });
  });
}
