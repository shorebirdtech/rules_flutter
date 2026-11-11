/// Native operations an app picks. Which libraries ship is decided at link
/// time: the package's link hook keeps the library of each [Op] the app
/// constructs.
library;

import 'dart:ffi';

import 'package:meta/meta.dart' show RecordUse;

/// An operation, named as its native library's code asset is.
///
/// Construct it with `const`: the link hook reads each constant's [name] from
/// the compiler's recorded uses and keeps only those libraries.
@RecordUse()
final class Op {
  /// Creates the operation called [name].
  const Op(this.name);

  /// The operation's name, its code asset's within the package.
  final String name;
}

/// Adds one, in `package:pick/kept`.
@Native<Int32 Function(Int32)>(
  assetId: 'package:pick/kept',
  symbol: 'pick_kept',
)
external int pickKept(int a);
