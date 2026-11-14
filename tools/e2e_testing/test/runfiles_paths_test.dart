import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';
import 'package:test/test.dart';

void main() {
  group('runfileKey', () {
    test('puts a workspace path in the main repository', () {
      expect(runfileKey('app/bundle'), '_main/app/bundle');
    });

    // `$(rootpaths ...)` writes a file of the workspace's root package as
    // `./name`, and a runfiles library refuses `_main/./name`.
    test('drops the "." segments Bazel writes for the root package', () {
      expect(runfileKey('./hello_world_web_web'), '_main/hello_world_web_web');
      expect(runfileKey('a/./b'), '_main/a/b');
    });
  });
}
