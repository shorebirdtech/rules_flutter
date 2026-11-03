/// Verifies the plugin_example Android APK packages every plugin's native
/// pieces — most importantly `libdartjni.so`, the C support library of
/// `package:jni` that jnigen-based plugins (path_provider_android >= 2.3)
/// load via `System.loadLibrary("dartjni")` in a static initializer. If the
/// library is missing, plugin registration aborts wholesale at startup with
/// an UnsatisfiedLinkError.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
library;

// This script's diagnostics are its product: it reports what it found in
// the built artifact to the bazel test log, so `print` is its output
// channel rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'package:rules_flutter_e2e_testing/apk.dart';
import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/elf.dart';

/// Classes the plugin closure requires at runtime, keyed by what ships them.
/// One representative class per source — if the class is not *defined* in
/// the APK's dex files, that piece is missing and the corresponding plugin
/// code path throws NoClassDefFoundError.
///
/// All listed classes are covered by keep rules (the registrant references
/// the plugin classes; package:jni's consumer-rules.pro keeps
/// com.github.dart_lang.jni.**), so their descriptors survive R8 renaming.
/// Dependencies without keep rules (e.g. kotlinx-coroutines) are
/// obfuscated by R8 and can't be asserted by name — R8 already fails the
/// build if a class referenced from a kept class is absent.
const _requiredDexClasses = <String, String>{
  'package:jni android/src (plugin class)':
      'Lcom/github/dart_lang/jni/JniPlugin;',
  'package:jni java/src (Gradle srcDirs — shared JNI support classes)':
      'Lcom/github/dart_lang/jni/PortContinuation;',
  'package:jni java/src (proxy support)':
      'Lcom/github/dart_lang/jni/PortProxyBuilder;',
  'package:jni_flutter android/src (plugin class)':
      'Lcom/github/dart_lang/jni_flutter/JniFlutterPlugin;',
};

/// Native libraries every plugin_example APK must carry for its ABI,
/// regardless of compilation mode.
const _requiredNativeLibs = <String, String>{
  'Flutter engine': 'libflutter.so',
  'package:jni C support library (System.loadLibrary("dartjni"))':
      'libdartjni.so',
};

/// The engine's libraries, as flutter.jar ships them: the Vulkan validation
/// layer is in the arm64 debug engine only.
const _engineLibs = ['libflutter.so', 'libVkLayer_khronos_validation.so'];

void main() {
  // Verify the ambient-configuration APK (release under a default
  // `bazel test`) and a copy force-built under `-c dbg` by the debug_apk
  // transition. Checking both in one default `bazel test //...` run exercises
  // the debug variant-manifest merge in both directions — INTERNET must be
  // absent from the release APK and present in the debug APK — without
  // building this test itself under `-c dbg`. The x64 APK must carry the
  // x86_64 engine and no other: the plugins compile against an arm64 one.
  final cases = [
    ('ambient', 'plugin_android.apk', null, 'arm64-v8a'),
    ('-c dbg', 'plugin_android_dbg.apk', true, 'arm64-v8a'),
    ('x64', 'plugin_android_x64.apk', null, 'x86_64'),
  ];

  // One log across the APKs, so one run names every problem in all of them.
  final check = BundleCheck();
  for (final (label, apkName, mustBeDebug, abi) in cases) {
    print('\n=== Verifying $label APK ($apkName) ===');
    final apk = Apk.fromRunfiles(
      apkName,
      prefix: 'plugin_apk_test',
      check: check,
    );
    final failuresBefore = check.failures.length;
    try {
      _verifyApk(apk, mustBeDebug: mustBeDebug, abi: abi);
      if (check.failures.length > failuresBefore) apk.listContents();
    } finally {
      apk.dispose();
    }
  }

  check.finish('\nAll plugin_example APK verification checks passed.');
}

/// Verifies a single APK built for [abi], an ABI directory name. [mustBeDebug]
/// asserts the detected compilation mode when non-null (the `-c dbg`
/// transition must yield a debug build); null accepts whatever the ambient
/// configuration produced.
void _verifyApk(Apk apk, {required bool? mustBeDebug, required String abi}) {
  final check = apk.check;

  // --- Compilation mode detection ---
  // Debug APKs run Dart from kernel_blob.bin inside flutter_assets (JIT);
  // release APKs AOT-compile it into lib/<abi>/libapp.so. Exactly one of
  // the two ships.
  final hasKernelBlob = apk
      .file('assets/flutter_assets/kernel_blob.bin')
      .existsSync();
  final hasLibApp = apk.file('lib/$abi/libapp.so').existsSync();
  if (hasKernelBlob == hasLibApp) {
    check.fail(
      'expected exactly one of kernel_blob.bin (debug) '
      'and libapp.so (release); found '
      '${hasKernelBlob ? "both" : "neither"}',
    );
  }
  final isDebug = hasKernelBlob;
  check.pass('APK is a ${isDebug ? "debug (JIT)" : "release (AOT)"} build');

  if (mustBeDebug != null && isDebug != mustBeDebug) {
    check.fail(
      'expected a ${mustBeDebug ? "debug" : "release"} '
      'APK but detected a ${isDebug ? "debug" : "release"} build — the '
      'compilation-mode transition did not apply',
    );
  }

  // --- INTERNET permission: present iff debug ---
  // flutter create declares android.permission.INTERNET only in
  // android/app/src/debug/AndroidManifest.xml; flutter_android_app merges
  // that variant manifest into -c dbg APKs (the Dart VM service cannot
  // bind without it) and must leave release APKs without it.
  final hasInternet = apk.fileHasText(
    'AndroidManifest.xml',
    'android.permission.INTERNET',
  );
  if (hasInternet == isDebug) {
    check.pass(
      'INTERNET permission '
      '${isDebug ? "present in debug" : "absent from release"} APK',
    );
  } else {
    check.fail(
      isDebug
          ? 'debug APK does not declare android.permission.INTERNET — '
                'the debug variant manifest did not merge'
          : 'release APK declares android.permission.INTERNET — the '
                'debug variant manifest leaked into a release build',
    );
  }

  // --- Native library presence ---
  _requiredNativeLibs.forEach((description, basename) {
    final path = 'lib/$abi/$basename';
    if (apk.file(path).existsSync()) {
      check.pass('$path ($description)');
    } else {
      check.fail('$path not found — $description');
    }
  });

  // --- Binary format checks ---
  // A library under another ABI's directory makes Android choose that ABI
  // when the device supports it, and then the app's own code (libapp.so) is
  // missing and the engine crashes at launch.
  final abis = apk.abis;
  if (abis.length == 1 && abis.single == abi) {
    check.pass('lib/ holds $abi only');
  } else {
    check.fail('expected lib/$abi only; found lib/{${abis.join(',')}}');
  }
  apk.checkNativeLibraries();

  // --- Engine stripping ---
  // Google ships the engine's libraries with full debug info; a Gradle
  // build strips them (llvm-strip --strip-unneeded) before packaging, in
  // every build type. Unstripped, the debug APK carries ~600 MB of symbols
  // the device never reads.
  for (final engineLib in _engineLibs.map((name) => 'lib/$abi/$name')) {
    final file = apk.file(engineLib);
    if (!file.existsSync()) continue;
    final sections = ElfImage.fromFile(file).sectionNames();
    final debugInfo = sections.where(
      (s) => s == '.symtab' || s.startsWith('.debug_'),
    );
    if (sections.isEmpty) {
      check.fail('$engineLib has no section headers to read');
    } else if (debugInfo.isNotEmpty) {
      check.fail('$engineLib is not stripped: has ${debugInfo.join(', ')}');
    } else {
      check.pass('$engineLib is stripped (no .symtab or .debug_* sections)');
    }
  }

  // --- Plugin runtime class checks ---
  apk.checkDefinedClasses(_requiredDexClasses);

  // --- Plugin resource + manifest merge checks (record_android) ---
  // record_android ships android/src/main/res/drawable/ic_mic.xml and a
  // library manifest declaring RECORD_AUDIO. Both must survive into the
  // APK: the resource entry name lands in resources.arsc's key string
  // pool, and the permission lands in the merged binary
  // AndroidManifest.xml (strings there are UTF-16 in binary XML).
  check
    ..expect(
      "resources.arsc defines ic_mic (record_android's drawable merged)",
      condition: apk.fileHasText('resources.arsc', 'ic_mic'),
      detail:
          "ic_mic not found in resources.arsc — record_android's res/ was "
          'dropped',
    )
    ..expect(
      'merged AndroidManifest.xml declares RECORD_AUDIO '
      "(record_android's library manifest merged)",
      condition: apk.fileHasText(
        'AndroidManifest.xml',
        'android.permission.RECORD_AUDIO',
      ),
      detail:
          'RECORD_AUDIO not found in the merged AndroidManifest.xml — '
          "record_android's manifest did not merge",
    );
}
