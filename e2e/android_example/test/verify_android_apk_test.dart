/// Verifies the Android APK produced by flutter_android_app has the
/// expected structure: classes.dex, native libs, flutter_assets, and manifest.
///
/// APK is a zip file — we extract it to a temp dir and verify contents.
library;

import 'package:rules_flutter_e2e_testing/apk.dart';

/// Classes the Flutter engine's Android embedding requires at app runtime,
/// keyed by the artifact that provides them. One representative class per
/// artifact — if the class is not *defined* in the APK's dex files, that
/// runtime dependency is missing and the app will throw NoClassDefFoundError
/// on the corresponding engine code path.
///
/// The direct engine dependencies mirror the dependency list of Flutter's
/// official io.flutter:flutter_embedding_* Maven POM (what every Gradle-built
/// Flutter app ships). The profileinstaller chain arrives transitively via
/// lifecycle-runtime and runs in every app ~6s after launch via an
/// androidx.startup initializer, so its own closure must also be complete —
/// including the real com.google.guava:listenablefuture jar (guava's empty
/// placeholder version would leave AbstractResolvableFuture's superinterface
/// undefined).
const _requiredDexClasses = <String, String>{
  'androidx.core:core': 'Landroidx/core/content/ContextCompat;',
  'androidx.exifinterface:exifinterface':
      'Landroidx/exifinterface/media/ExifInterface;',
  'androidx.fragment:fragment': 'Landroidx/fragment/app/Fragment;',
  'androidx.lifecycle:lifecycle-common': 'Landroidx/lifecycle/Lifecycle;',
  'androidx.lifecycle:lifecycle-runtime':
      'Landroidx/lifecycle/LifecycleRegistry;',
  'androidx.tracing:tracing': 'Landroidx/tracing/Trace;',
  'androidx.window:window': 'Landroidx/window/layout/WindowInfoTracker;',
  'androidx.window:window-java':
      'Landroidx/window/java/layout/WindowInfoTrackerCallbackAdapter;',
  'com.getkeepsafe.relinker:relinker': 'Lcom/getkeepsafe/relinker/ReLinker;',
  'androidx.profileinstaller:profileinstaller (via lifecycle-runtime)':
      'Landroidx/profileinstaller/ProfileInstaller;',
  'androidx.concurrent:concurrent-futures (via profileinstaller)':
      'Landroidx/concurrent/futures/AbstractResolvableFuture;',
  'com.google.guava:listenablefuture (AbstractResolvableFuture supertype)':
      'Lcom/google/common/util/concurrent/ListenableFuture;',
};

void main() {
  final apk = Apk.fromRunfiles('app.apk', prefix: 'android_apk_test');

  // --- Structural checks ---

  apk.check
    ..exists('classes.dex exists', '${apk.path}/classes.dex')
    ..exists(
      'libapp.so exists (arm64-v8a)',
      '${apk.path}/lib/arm64-v8a/libapp.so',
    )
    ..exists(
      'libflutter.so exists (arm64-v8a)',
      '${apk.path}/lib/arm64-v8a/libflutter.so',
    )
    ..exists(
      'libadd.so exists (arm64-v8a, from native_deps)',
      '${apk.path}/lib/arm64-v8a/libadd.so',
    )
    ..exists(
      'libnegate.so exists (arm64-v8a, a prebuilt code asset)',
      '${apk.path}/lib/arm64-v8a/libnegate.so',
    )
    ..exists(
      'flutter_assets directory exists',
      '${apk.path}/assets/flutter_assets',
    )
    ..exists(
      'AssetManifest.bin exists',
      '${apk.path}/assets/flutter_assets/AssetManifest.bin',
    )
    ..exists(
      'FontManifest.json exists',
      '${apk.path}/assets/flutter_assets/FontManifest.json',
    )
    ..exists('AndroidManifest.xml exists (binary format)', apk.manifest.path);

  // --- Binary format checks ---
  apk
    ..checkNativeLibraries()
    ..checkNativeLibraryApiLevels()
    // --- Packaging, as AGP packages a Flutter app ---
    ..checkNativeLibrariesUncompressed()
    ..checkNoMultiplatformMetadata()
    ..checkNoCoreLibraryDesugaring()
    // --- Engine runtime class checks ---
    ..checkDefinedClasses(_requiredDexClasses)
    ..finish('\nAll Android APK verification checks passed.');
}
