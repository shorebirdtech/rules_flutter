/// The prebuilt native `negate` via FFI on platforms with `dart:ffi`; a stub
/// elsewhere (web).
library;

export 'negate_stub.dart' if (dart.library.ffi) 'negate_ffi.dart';
