/// Verifies the add-to-app xcframeworks of a release build carry the code
/// asset `pick`'s link hook kept and not the one it dropped, and that the
/// Swift package lists the same.
///
/// Arguments: the layout target, then the kept and the dropped xcframework,
/// each named without `.xcframework`.
library;

import 'dart:io';

import 'package:rules_flutter_e2e_testing/bundle_check.dart';
import 'package:rules_flutter_e2e_testing/runfiles_paths.dart';

void main(List<String> args) {
  final [layout, kept, dropped] = args;
  final release = '${requireRunfile(layout, what: 'The layout')}/Release';
  final check = BundleCheck()
    ..exists('the kept $kept.xcframework', '$release/$kept.xcframework')
    ..absent(
      'the dropped $dropped.xcframework',
      '$release/$dropped.xcframework',
    );
  final package = File('$release/Package.swift').readAsStringSync();
  check
    ..expect(
      'Package.swift names $kept',
      condition: package.contains('.binaryTarget(name: "$kept"'),
      detail: package,
    )
    ..expect(
      'Package.swift leaves out $dropped',
      condition: !package.contains('"$dropped"'),
      detail: package,
    )
    ..finish('The add-to-app layout ships what the link hook kept.');
}
