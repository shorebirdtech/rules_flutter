/// Reading what a restart needs of a launch bundle, short of the launch artifact.
library;

/// Where to read the native libraries and assets of the app a launch target
/// packages without building the launch target itself.
///
/// The launch target of an Android run packages an APK, that of an Apple run a
/// bundle whose `App.framework` holds the app's kernel, and that of a Linux or
/// Windows run a bundle that copies the kernel in; the libraries and assets are
/// built before any of them. An aspect over the launch target collects
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

/// The aspect that collects an iOS app's assets and native code inputs, for the
/// simulator and a device alike.
const iosBundlePartsAspect =
    '@rules_flutter//flutter:ios_bundle_parts.bzl%'
    'flutter_ios_bundle_parts_aspect';

/// The output group of [iosBundlePartsAspect] that holds the assets.
const iosBundlePartsOutputGroup = 'flutter_ios_bundle_parts';

/// The output group of [iosBundlePartsAspect] that holds the native code
/// inputs.
const iosNativeLibsOutputGroup = 'flutter_ios_native_libs';

/// The aspect that collects a Linux bundle's assets and native code inputs.
const linuxBundlePartsAspect =
    '@rules_flutter//flutter:linux_bundle_parts.bzl%'
    'flutter_linux_bundle_parts_aspect';

/// The output group of [linuxBundlePartsAspect] that holds the assets.
const linuxBundlePartsOutputGroup = 'flutter_linux_bundle_parts';

/// The output group of [linuxBundlePartsAspect] that holds the native code
/// inputs.
const linuxNativeLibsOutputGroup = 'flutter_linux_native_libs';

/// The aspect that collects a Windows bundle's assets and native code inputs.
const windowsBundlePartsAspect =
    '@rules_flutter//flutter:windows_bundle_parts.bzl%'
    'flutter_windows_bundle_parts_aspect';

/// The output group of [windowsBundlePartsAspect] that holds the assets.
const windowsBundlePartsOutputGroup = 'flutter_windows_bundle_parts';

/// The output group of [windowsBundlePartsAspect] that holds the native code
/// inputs.
const windowsNativeLibsOutputGroup = 'flutter_windows_native_libs';
