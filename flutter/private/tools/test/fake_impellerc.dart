/// Stands in for `impellerc` in `compile_shader_test.dart`: like the real one
/// on an Impeller-only shader, it fails whenever it is asked for SkSL
/// (`--sksl`) and succeeds otherwise.
library;

import 'dart:io';

void main(List<String> args) {
  if (args.contains('--sksl')) {
    stderr.writeln('error: index expression must be constant');
    exit(1);
  }
}
