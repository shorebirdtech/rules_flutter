import 'package:rules_flutter_e2e_testing/macos_windows.dart';
import 'package:test/test.dart';

void main() {
  group('AppWindows.assessEnumeration', () {
    test('windows among the processes read is healthy', () {
      expect(
        AppWindows.assessEnumeration(
          exitCode: 0,
          stdout: '7,12,0\n',
          stderr: '',
        ),
        isNull,
      );
    });

    test('windows are enough even when some processes could not be read', () {
      expect(
        AppWindows.assessEnumeration(exitCode: 0, stdout: '7,12,3', stderr: ''),
        isNull,
      );
    });

    test('an error from System Events is not "no windows"', () {
      // What a busy Mac answers when a process exits while the list is read.
      final problem = AppWindows.assessEnumeration(
        exitCode: 1,
        stdout: '',
        stderr:
            'execution error: System Events got an error: Can’t get every '
            'process whose background only = false. Invalid index. (-1719)',
      );
      expect(problem, isNotNull);
      expect(problem, contains('-1719'));
      expect(problem, contains('did not answer'));
      expect(problem, isNot(contains('reports no windows')));
    });

    test('a genuine zero says no windows, and for how many processes', () {
      final problem = AppWindows.assessEnumeration(
        exitCode: 0,
        stdout: '0,12,0',
        stderr: '',
      );
      expect(problem, contains('reports no windows for any of 12 processes'));
    });

    test('processes that could not be read are not counted as windowless', () {
      final problem = AppWindows.assessEnumeration(
        exitCode: 0,
        stdout: '0,0,9',
        stderr: '',
      );
      expect(problem, contains('could not read'));
      expect(problem, contains('9'));
      expect(problem, isNot(contains('reports no windows')));
    });

    test('a mix of windowless processes and unreadable ones says both', () {
      final problem = AppWindows.assessEnumeration(
        exitCode: 0,
        stdout: '0,5,2',
        stderr: '',
      );
      expect(problem, contains('no windows for the 5 processes it could read'));
      expect(problem, contains('2'));
    });

    test('output that is not a reading is reported as it came', () {
      final problem = AppWindows.assessEnumeration(
        exitCode: 0,
        stdout: 'surprise',
        stderr: '',
      );
      expect(problem, contains('surprise'));
    });
  });
}
