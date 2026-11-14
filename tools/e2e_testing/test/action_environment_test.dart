import 'package:rules_flutter_e2e_testing/action_environment.dart';
import 'package:test/test.dart';

void main() {
  const host = {
    'SystemRoot': r'C:\Windows',
    'SYSTEMDRIVE': 'C:',
    'PATH': r'C:\host',
  };

  test('on macOS and Linux it is the action\'s with TMPDIR', () {
    expect(
      actionEnvironment(
        {'PATH': '/bin', 'LANG': 'C'},
        tmp: '/t/tmp_0',
        host: host,
        windows: false,
      ),
      {'PATH': '/bin', 'LANG': 'C', 'TMPDIR': '/t/tmp_0'},
    );
  });

  test('on Windows it adds TMP, TEMP, SYSTEMROOT and SYSTEMDRIVE', () {
    expect(
      actionEnvironment(
        {'PATH': r'C:\tools'},
        tmp: 'C:/t/tmp_0',
        host: host,
        windows: true,
      ),
      {
        'PATH': r'C:\tools',
        'SYSTEMROOT': r'C:\Windows',
        'SYSTEMDRIVE': 'C:',
        'TMP': r'C:\t\tmp_0',
        'TEMP': r'C:\t\tmp_0',
      },
    );
  });

  test('on Windows an empty action environment is not empty', () {
    expect(
      actionEnvironment(const {}, tmp: r'C:\t', host: host, windows: true),
      isNotEmpty,
    );
  });

  test('on Windows the action\'s own SYSTEMROOT stands, its TMP does not', () {
    final env = actionEnvironment(
      {'SystemRoot': r'D:\Win', 'temp': r'C:\elsewhere'},
      tmp: r'C:\t',
      host: host,
      windows: true,
    );
    expect(env, {
      'SystemRoot': r'D:\Win',
      'SYSTEMDRIVE': 'C:',
      'TMP': r'C:\t',
      'TEMP': r'C:\t',
    });
  });
}
