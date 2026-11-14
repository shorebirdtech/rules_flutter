/// `negate`, from a prebuilt library file bound to this package's asset id.
@DefaultAsset('package:prebuilt_asset/negate')
library;

import 'dart:ffi';

/// Call the native `negate` function.
@Native<Int32 Function(Int32)>()
external int negate(int a);
