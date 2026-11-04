/// Which operating systems CI runs each e2e workspace on, and the matrix
/// `.github/workflows/ci.yaml` builds from it.
///
/// This table is the one place that says so. A job costs runner time, so each
/// one has to earn it: a workspace runs on a system only where it exercises
/// something there that no other job does, and its entry says what. That is an
/// OS-specific path (a runner, a toolchain, a bundle layout, a plugin's
/// implementation for that platform, how the host loads a library), or, for a
/// workspace whose subject does not depend on the OS, the one run it needs at
/// all, on the cheapest system that builds it. Everywhere else it names why it
/// does not run: what covers it instead, or that the system cannot build it.
///
/// Every workspace under `e2e/` must be listed and must account for each of the
/// three systems. A workspace added without an entry fails the `plan` job, as
/// does an entry for a workspace that is gone, a run without a purpose, or the
/// same purpose given for two systems (which says the second adds nothing).
library;

/// An operating system a CI job runs on.
enum Os {
  macos('macos-latest'),
  linux('ubuntu-latest'),
  windows('windows-latest');

  const Os(this.runner);

  /// The `runs-on` label of the GitHub-hosted runner.
  final String runner;
}

/// One e2e workspace and what CI does with it on each operating system.
class E2eWorkspace {
  const E2eWorkspace(
    this.name, {
    this.runs = const {},
    this.skips = const {},
    this.command = 'test',
  });

  /// The directory under `e2e/`, with `/` separators.
  final String name;

  /// The systems it runs on, each with what it exercises there that no other
  /// job does.
  final Map<Os, String> runs;

  /// The systems it does not run on, each with why: the job that covers it
  /// instead, or that the system cannot build it.
  final Map<Os, String> skips;

  /// The Bazel command run in the workspace: `test`, or `build` where a
  /// workspace has no test targets (`bazel test` exits 4 for those).
  final String command;
}

const _appleOnly =
    'every test is target_compatible_with macOS: it builds Apple bundles, '
    'which no other host can analyse';

const _linuxOnly = 'every test is target_compatible_with Linux';

const _windowsOnly = 'every test is target_compatible_with Windows';

const _webElsewhere =
    'web bundles are platform-neutral; hello_world builds one on this host, '
    'which is what depends on it (the host web compilers and wasm-opt)';

const e2eWorkspaces = <E2eWorkspace>[
  // The BCR presubmit module (.bcr/presubmit.yml), which BCR runs on Debian,
  // Ubuntu, macOS and Windows before it accepts a release. Each job is the
  // minimal consumer's toolchain resolving on that host, with none of the
  // modules a fuller workspace declares to hide a gap. About a minute each.
  E2eWorkspace(
    'smoke',
    runs: {
      Os.macos: 'the BCR presubmit module resolving its toolchain on a Mac',
      Os.linux:
          'the BCR presubmit module resolving its toolchain on Linux (BCR '
          'runs Debian and Ubuntu)',
      Os.windows: 'the BCR presubmit module resolving its toolchain on Windows',
    },
  ),
  E2eWorkspace(
    'dual_hub',
    runs: {
      Os.linux:
          'two pub hubs over two locks: the only coverage of duplicate package '
          'records across hubs. Pure Dart, no Flutter app; one run, on the '
          'cheapest runner',
    },
    skips: {
      Os.macos: 'pure Dart with nothing OS-specific; Linux runs it',
      Os.windows: 'pure Dart with nothing OS-specific; Linux runs it',
    },
  ),
  // Also the one job per system that saves the repository cache (ci.yaml).
  E2eWorkspace(
    'hello_world',
    runs: {
      Os.macos:
          'Tier-1 flutter_macos_app and flutter_ios_app over the `flutter '
          'create` runners (entitlements, app icon), the iOS simulator bundle, '
          'Android and web built from a Mac, flutter_test under the macOS '
          'flutter_tester',
      Os.linux:
          'Tier-1 flutter_linux_app over the `flutter create` GTK runner, its '
          'profile-mode bundle (a profile AOT snapshot builds only on its own '
          'OS), Android and web built from Linux, flutter_test under the Linux '
          'flutter_tester',
      Os.windows:
          'Tier-1 flutter_windows_app over the `flutter create` Win32 runner, '
          'its profile-mode bundle (buildable only on Windows), web built from '
          'Windows, flutter_test under the Windows flutter_tester with '
          'manifest-only runfiles',
    },
  ),
  // The codegen, gen-l10n and golden tests here are platform-neutral and ride
  // along; what each system adds is how its flutter_tester loads a native
  // library, which only this workspace tests.
  //
  // Expected to fail on Windows until fixed: `:native_asset_program` is a
  // flutter_tester_binary, whose runner has no Windows loader path and throws
  // (`libraryPathEnvironment` in flutter_test_runner.dart). hello_world keeps
  // its own flutter_tester_binary off Windows for that reason.
  E2eWorkspace(
    'codegen',
    runs: {
      Os.macos:
          'Native Assets under the macOS flutter_tester (a .dylib by runfiles '
          'path in flutter_test, by DYLD_LIBRARY_PATH in flutter_tester_binary), '
          'and the Bazel-generated macOS runner over a source-assembled '
          '(.pkgsrcs) package, the build half of codegen hot reload',
      Os.linux:
          'Native Assets under the Linux flutter_tester: a .so by runfiles path '
          'in flutter_test, by LD_LIBRARY_PATH in flutter_tester_binary, and '
          'under a platform transition',
      Os.windows:
          'Native Assets under the Windows flutter_tester: a .dll found through '
          'manifest-only runfiles',
    },
  ),
  // Expected to fail on Linux until fixed: the `flutter create` Linux runner
  // reads APPLICATION_ID, which `linux_runner_defines` does not define.
  E2eWorkspace(
    'plugin_example',
    runs: {
      Os.macos:
          'pub plugins\' Apple implementations (SwiftPM path_provider_foundation, '
          'shared_preferences_foundation, url_launcher_macos) and their privacy '
          'manifests in the macOS and iOS simulator bundles',
      Os.linux:
          'pub plugins\' Linux implementations (C++ url_launcher_linux, Dart '
          'path_provider_linux and shared_preferences_linux) registered in the '
          '`flutter create` Linux runner',
      Os.windows:
          'pub plugins\' Windows implementations (C++ url_launcher_windows, Dart '
          'path_provider_windows and shared_preferences_windows) registered in '
          'the `flutter create` Win32 runner',
    },
  ),
  E2eWorkspace(
    'ffi_example',
    runs: {
      Os.macos:
          'native_deps libraries and Native Assets code assets linked by the '
          'Apple toolchain into the macOS .app\'s Frameworks and the iOS '
          'simulator bundle',
      Os.linux:
          'native_deps libraries and Native Assets code assets as ELF shared '
          'libraries (with -ldl) in the Linux bundle\'s lib/',
      Os.windows:
          'native_deps libraries and Native Assets code assets as DLLs beside '
          'the Windows bundle\'s .exe',
    },
  ),
  E2eWorkspace(
    'ffi_plugin_example',
    runs: {
      Os.linux:
          'a Bazel flutter_plugin carrying native_deps and a dart_plugin_class, '
          'its library bundled into the app. How a bundle carries a native '
          'library is ffi_example\'s on each system; this path is '
          'platform-neutral, so one run, on the cheapest runner',
    },
    skips: {
      Os.macos:
          'ffi_example covers native libraries in Apple bundles; the plugin '
          'path is platform-neutral and runs on Linux',
      Os.windows: 'the workspace builds no Windows bundle',
    },
  ),
  E2eWorkspace(
    'web_example',
    runs: {
      Os.linux:
          'the web bundle\'s variants (wasm with JS fallback, wasm-only, '
          'subpath, PWA and service worker, browser allow-list, compiler flags, '
          'profile): platform-neutral, so one run, on the cheapest runner',
    },
    skips: {Os.macos: _webElsewhere, Os.windows: _webElsewhere},
  ),
  E2eWorkspace(
    'android_example',
    runs: {
      Os.linux:
          'Android app variants (a second app, permissions, the Bazel-generated '
          'and custom Kotlin runners, NDK code assets): platform-neutral past '
          'the host tools, so one run, on the cheapest runner',
    },
    skips: {
      Os.macos:
          'hello_world and plugin_example build Android from a Mac, which is '
          'what depends on the host (aapt2, the NDK, gen_snapshot)',
      Os.windows:
          'rules_android compiles resources in a JVM that commits 3 GiB at '
          'start, which windows-latest cannot, and every target of the '
          'workspace is an Android one',
    },
  ),
  // Pins `--platforms=linux_x64` for every command, so it has no test
  // targets: CI builds it.
  E2eWorkspace(
    'cross_compile_example',
    runs: {
      Os.macos:
          'the Linux bundle cross-compiled from a Mac: the macOS-to-Linux C++ '
          'toolchain and the Linux sysroot, which no Linux runner uses',
    },
    skips: {
      Os.linux:
          'on a Linux host the target is an ordinary native Linux bundle, '
          'which hello_world and linux_example build',
      Os.windows: 'the Flutter toolchain has no Windows-to-Linux pair',
    },
    command: 'build',
  ),
  E2eWorkspace(
    'macos_example',
    runs: {
      Os.macos:
          'macOS-only features: app extensions and App Intents, team signing, '
          'entitlements, two apps from one package, the Tier-2 Bazel-generated '
          'and custom runners, the profile-mode app',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  E2eWorkspace(
    'ios_example',
    runs: {
      Os.macos:
          'iOS-only features: app extensions and App Intents, Info.plist and '
          'app icon, two apps from one package, the simulator refusing '
          'fastbuild, the Tier-2 Bazel-generated and custom runners',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  E2eWorkspace(
    'multi_window_example',
    runs: {
      Os.macos:
          'a hand-written runner with two windows on one FlutterEngineGroup '
          '(two Dart entry points in one compilation), on macOS and as UIScene '
          'scenes on iOS',
    },
    skips: {Os.linux: _appleOnly, Os.windows: _appleOnly},
  ),
  // Its test reads the flutter_application's bundle, not the macOS app, and
  // the link hook runs over the host's release AOT compile.
  E2eWorkspace(
    '_overlay_tests/link_hooks',
    runs: {
      Os.linux:
          'package link hooks over the uses a release compile records, and the '
          'hook\'s asset in the bundle: platform-neutral, so one run, on the '
          'cheapest runner',
    },
    skips: {
      Os.macos: 'platform-neutral; Linux runs it',
      Os.windows: 'platform-neutral; Linux runs it',
    },
  ),
  E2eWorkspace(
    '_overlay_tests/native_assets_synthetic',
    runs: {
      Os.macos:
          'a flutter_native_asset over a hand-linked dylib with its own install '
          'name, and a flutter_data_asset (built nowhere else), reaching an app '
          'through an otherwise empty flutter_plugin',
    },
    skips: {
      Os.linux:
          'its one test includes the macOS-only dylib, so it is incompatible '
          'here and nothing runs',
      Os.windows:
          'its one test includes the macOS-only dylib, so it is incompatible '
          'here and nothing runs',
    },
  ),
  E2eWorkspace(
    'linux_example',
    runs: {
      Os.linux:
          'Tier-2 Linux rules: engine, registrant and the Bazel-generated GTK '
          'runner composed by hand, and the window title',
    },
    skips: {Os.macos: _linuxOnly, Os.windows: _linuxOnly},
  ),
  E2eWorkspace(
    'windows_example',
    runs: {
      Os.windows:
          'Tier-2 Windows rules: the Bazel-generated Win32 runner and a custom '
          'cc_binary runner',
    },
    skips: {Os.macos: _windowsOnly, Os.linux: _windowsOnly},
  ),
];

/// What is wrong with [table] as a description of [found], the workspaces
/// under `e2e/` (as `e2e/<name>`, the form `findWorkspaces` returns); empty
/// when nothing is.
List<String> matrixProblems(
  List<E2eWorkspace> table,
  Iterable<String> found,
) {
  final problems = <String>[];
  final listed = <String>{};
  for (final workspace in table) {
    final name = workspace.name;
    if (!listed.add(name)) problems.add('$name is listed twice');
    for (final os in Os.values) {
      final runs = workspace.runs[os];
      final skips = workspace.skips[os];
      if (runs != null && skips != null) {
        problems.add('$name both runs and is skipped on ${os.name}');
      } else if (runs == null && skips == null) {
        problems.add(
          '$name neither runs on ${os.name} nor says why not',
        );
      } else if (runs != null && runs.trim().isEmpty) {
        problems.add(
          '$name runs on ${os.name} without saying what it exercises there '
          'that no other job does',
        );
      } else if (skips != null && skips.trim().isEmpty) {
        problems.add('$name is skipped on ${os.name} without a reason');
      }
    }
    final systems = <String, Os>{};
    for (final MapEntry(key: os, value: purpose) in workspace.runs.entries) {
      final first = systems.putIfAbsent(purpose.trim(), () => os);
      if (first != os && purpose.trim().isNotEmpty) {
        problems.add(
          '$name gives ${first.name} and ${os.name} the same purpose: say what '
          'each system adds, or run it on one',
        );
      }
    }
  }
  final existing = {for (final path in found) path.replaceFirst('e2e/', '')};
  for (final name in existing.difference(listed)) {
    problems.add(
      'e2e/$name is in no entry: add it to e2eWorkspaces in '
      'tools/ci_matrix/e2e_matrix.dart, with what it exercises on each system '
      'it runs on',
    );
  }
  for (final name in listed.difference(existing)) {
    problems.add('e2eWorkspaces lists e2e/$name, which does not exist');
  }
  return problems..sort();
}

/// The jobs of [table] as the `include` list of a GitHub Actions matrix, in
/// table order, one per workspace and system it runs on.
List<Map<String, String>> matrixInclude(List<E2eWorkspace> table) => [
  for (final workspace in table)
    for (final os in Os.values)
      if (workspace.runs.containsKey(os))
        {
          'workspace': workspace.name,
          'os': os.runner,
          'command': workspace.command,
        },
];
