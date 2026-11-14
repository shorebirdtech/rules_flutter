/// `negate`, from a prebuilt library file bound to `package:prebuilt_asset`'s
/// asset id (`//:negate_asset`).
library;

import 'dart:ffi';

/// Call the native `negate` function.
@Native<Int32 Function(Int32)>(assetId: 'package:prebuilt_asset/negate')
external int negate(int a);
