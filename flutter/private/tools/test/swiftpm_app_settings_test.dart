import 'package:test/test.dart';

import '../swiftpm_app_settings.dart';

/// A `dump-package` of a manifest with one target, `permission_handler_apple`
/// in shape: header search paths, and the defines it computed.
Map<String, Object?> _dump({
  List<Map<String, Object?>> defines = const [],
  List<Map<String, Object?>> other = const [],
  String root = '/tmp/a',
  String dependencyPath = '/tmp/a/../shared',
}) => {
  'name': 'permission_handler_apple',
  'packageKind': {
    'root': [root],
  },
  'dependencies': [
    {
      'fileSystem': [
        {'identity': 'shared', 'path': dependencyPath},
      ],
    },
  ],
  'products': [
    {
      'name': 'permission-handler-apple',
      'targets': ['permission_handler_apple'],
      'type': {
        'library': ['automatic'],
      },
    },
  ],
  'targets': [
    {
      'name': 'permission_handler_apple',
      'path': 'Sources/permission_handler_apple',
      'type': 'regular',
      'settings': [
        {
          'kind': {
            'headerSearchPath': {'_0': 'strategies'},
          },
          'tool': 'c',
        },
        ...other,
        ...defines,
      ],
    },
  ],
};

Map<String, Object?> _define(
  String value, {
  String tool = 'c',
  Map<String, Object?>? condition,
}) => {
  'kind': {
    'define': {'_0': value},
  },
  'tool': tool,
  if (condition != null) 'condition': condition,
};

TargetDefines _defines(
  Map<String, Object?> dump, {
  Map<String, Object?>? reference,
  String platform = 'ios',
  String configuration = 'debug',
}) => targetDefines(
  dump: dump,
  reference: reference ?? _dump(),
  target: 'permission_handler_apple',
  platform: platform,
  configuration: configuration,
);

void main() {
  test("takes the app's defines, C-family and Swift apart", () {
    final defines = _defines(
      _dump(
        defines: [
          _define('PERMISSION_CAMERA=1'),
          _define('PERMISSION_CONTACTS=0', tool: 'cxx'),
          _define('FEATURE', tool: 'swift'),
        ],
      ),
    );
    expect(defines.clang, ['PERMISSION_CAMERA=1', 'PERMISSION_CONTACTS=0']);
    expect(defines.swift, ['FEATURE']);
    expect(
      defines.header,
      contains('#define PERMISSION_CAMERA 1\n#define PERMISSION_CONTACTS 0\n'),
    );
    expect(defines.swiftParams, '-DFEATURE\n');
  });

  test('a define without a value is 1, one with an empty value is empty', () {
    final defines = _defines(
      _dump(defines: [_define('ON'), _define('EMPTY=')]),
    );
    expect(defines.header, contains('#define ON 1\n#define EMPTY \n'));
  });

  test("keeps only the defines of the platform and configuration", () {
    final dump = _dump(
      defines: [
        _define(
          'IOS_ONLY',
          condition: {
            'platformNames': ['ios'],
          },
        ),
        _define(
          'MACOS_ONLY',
          condition: {
            'platformNames': ['macos'],
          },
        ),
        _define('DEBUG_ONLY', condition: {'config': 'debug'}),
        _define('RELEASE_ONLY', condition: {'config': 'release'}),
      ],
    );
    expect(_defines(dump).clang, ['IOS_ONLY', 'DEBUG_ONLY']);
    expect(
      _defines(dump, platform: 'macos', configuration: 'release').clang,
      ['MACOS_ONLY', 'RELEASE_ONLY'],
    );
  });

  test('a manifest with no defines gives an empty response file', () {
    final defines = _defines(_dump());
    expect(defines.clang, isEmpty);
    expect(defines.swiftParams, '');
  });

  test('where it was evaluated may differ', () {
    expect(
      () => _defines(
        _dump(root: '/sandbox/b', dependencyPath: '/sandbox/shared'),
      ),
      returnsNormally,
    );
  });

  test('anything else that differs fails, naming it', () {
    final changed = _dump(
      other: [
        {
          'kind': {
            'unsafeFlags': {
              '_0': ['-fno-objc-arc'],
            },
          },
          'tool': 'c',
        },
      ],
    );
    expect(
      () => _defines(changed),
      throwsA(
        isA<ManifestMismatch>().having(
          (e) => e.differences.single,
          'difference',
          startsWith('targets[permission_handler_apple].settings'),
        ),
      ),
    );
  });

  test('a target the manifest does not have fails', () {
    expect(
      () => targetDefines(
        dump: _dump(),
        reference: _dump(),
        target: 'other',
        platform: 'ios',
        configuration: 'debug',
      ),
      throwsFormatException,
    );
  });
}
