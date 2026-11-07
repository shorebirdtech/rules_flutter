import 'dart:ffi';

/// Adds two numbers in the plugin's C code, which Dart looks up by name in
/// the app's own symbols.
int ffiDynamicPluginAdd(int a, int b) => DynamicLibrary.process()
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'ffi_dynamic_plugin_add',
    )(a, b);
