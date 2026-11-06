/// Reading what a restart needs of a launch bundle, short of the launch artifact.
library;

/// Where to read the native libraries and assets of the app a launch target
/// packages without building the launch target itself.
///
/// The launch target of an Android run packages an APK, and that of a macOS
/// run a bundle whose `App.framework` holds the app's kernel; the libraries and
/// assets are built before either. An aspect over the launch target collects
/// them in the configuration the artifact used, and building only its output
/// groups builds only them.
class LaunchBundleParts {
  /// The aspect that fills the groups, as `--aspects` takes it.
  final String aspect;

  /// The output group that holds the assets tree.
  final String assetsGroup;

  /// The output group that holds the files the launch artifact takes its
  /// native libraries from: every one it packages, not only the application's.
  final String nativeLibsGroup;

  const LaunchBundleParts({
    required this.aspect,
    required this.assetsGroup,
    required this.nativeLibsGroup,
  });
}

/// The aspect that collects an Android bundle's assets and native libraries.
const androidBundlePartsAspect =
    '@rules_flutter//flutter:android_bundle_parts.bzl%'
    'flutter_android_bundle_parts_aspect';

/// The output group of [androidBundlePartsAspect] that holds the assets.
const androidBundlePartsOutputGroup = 'flutter_android_bundle_parts';

/// The output group of [androidBundlePartsAspect] that holds the native
/// libraries' inputs.
const androidNativeLibsOutputGroup = 'flutter_android_native_libs';

/// The aspect that collects a macOS bundle's assets and native code inputs.
const macosBundlePartsAspect =
    '@rules_flutter//flutter:macos_bundle_parts.bzl%'
    'flutter_macos_bundle_parts_aspect';

/// The output group of [macosBundlePartsAspect] that holds the assets.
const macosBundlePartsOutputGroup = 'flutter_macos_bundle_parts';

/// The output group of [macosBundlePartsAspect] that holds the native code
/// inputs.
const macosNativeLibsOutputGroup = 'flutter_macos_native_libs';
