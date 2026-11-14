/// Property: a release iOS app keeps the C symbols of an FFI plugin whose Swift
/// package product is `.dynamic`.
///
/// `flutter build ios --release` embeds such a product as a framework, whose
/// global symbols all stay, and Dart looks them up with
/// `DynamicLibrary.process()`. Here the product is linked into the app, whose
/// release link removes code nothing references: `ffi_dynamic_plugin_add`, a
/// plain C function that only Dart calls, has to survive it.
///
/// `libremidi_flutter`'s functions are marked `used`, as an FFI plugin has to
/// for a product that is not `.dynamic`, and stay either way.
library;

import 'package:rules_flutter_e2e_testing/ios_bundle.dart';
import 'package:rules_flutter_e2e_testing/mach_o.dart';

void main() {
  final bundle = IosBundle.fromRunfiles(
    'swiftpm_plugins_app_device.ipa',
    prefix: 'ios_release_ffi_symbols_test',
  );
  try {
    for (final (plugin, symbol) in [
      ('ffi_dynamic_plugin, a .dynamic product', ' T _ffi_dynamic_plugin_add'),
      ('libremidi_flutter, which marks its functions', ' T _lrm_observer_new'),
    ]) {
      bundle.check.expect(
        'the release app exports the function of $plugin',
        condition: bundle.rootFiles.any(
          (f) => MachO(f.path).hasSymbolContaining(symbol),
        ),
      );
    }
    bundle.finish('The release app keeps the symbols of its FFI plugins.');
  } finally {
    bundle.dispose();
  }
}
