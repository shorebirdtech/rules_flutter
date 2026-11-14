import 'package:test/test.dart';

import '../libraries_spec.dart';

const _sdkSpec = <String, Object?>{
  'vm_common': {
    'libraries': {
      'core': {
        'uri': 'core/core.dart',
        'patches': ['_internal/vm/lib/core_patch.dart'],
      },
      'io': {'uri': 'io/io.dart', 'patches': '_internal/vm/bin/io_patch.dart'},
      'isolate': {'uri': 'isolate/isolate.dart'},
      'mirrors': {'uri': 'mirrors/mirrors.dart'},
    },
  },
  'vm': {
    'include': [
      {'target': 'vm_common'},
    ],
    'libraries': {
      'cli': {'uri': 'cli/cli.dart'},
    },
  },
  'dart2js': {
    'libraries': {
      'html': {'uri': 'html/dart2js/html_dart2js.dart'},
    },
  },
};

void main() {
  test('names the VM common libraries less mirrors, plus ui', () {
    final spec = flutterLibrariesSpec(_sdkSpec, 'dart-sdk/lib/');
    expect(spec.keys.where((k) => !k.startsWith('comment:')), ['flutter']);
    final libraries = (spec['flutter'] as Map)['libraries'] as Map;
    expect(libraries.keys.toList()..sort(), ['core', 'io', 'isolate', 'ui']);
  });

  test('rebases the SDK paths onto the written file', () {
    final spec = flutterLibrariesSpec(_sdkSpec, 'dart-sdk/lib/');
    final libraries = (spec['flutter'] as Map)['libraries'] as Map;
    expect(libraries['core']['uri'], 'dart-sdk/lib/core/core.dart');
    expect(libraries['core']['patches'], [
      'dart-sdk/lib/_internal/vm/lib/core_patch.dart',
    ]);
    expect(
      libraries['io']['patches'],
      'dart-sdk/lib/_internal/vm/bin/io_patch.dart',
    );
    expect(libraries['isolate'].containsKey('patches'), isFalse);
  });

  test('relativeDirectory climbs out of the output directory', () {
    expect(
      relativeDirectory('out/a/spec.json', 'external/sdk/lib/'),
      '../../external/sdk/lib/',
    );
    expect(relativeDirectory('spec.json', 'lib/'), 'lib/');
  });
}
