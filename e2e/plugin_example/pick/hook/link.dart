// Keeps the native library of each operation the app constructs, out of the
// package's two, and drops the rest.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:record_use/record_use.dart';

const _op = Class('Op', Library('package:pick/pick.dart'));

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    final used = {
      for (final use in input.recordedUses?.instances[_op] ?? const [])
        if (use case InstanceConstantReference(
          instanceConstant: InstanceConstant(
            fields: {'name': StringConstant(value: final name)},
          ),
        ))
          name,
    };
    for (final asset in input.assets.code) {
      if (used.contains(asset.id.substring('package:pick/'.length))) {
        output.assets.code.add(asset);
      }
    }
  });
}
