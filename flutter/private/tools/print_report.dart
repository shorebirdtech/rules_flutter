/// Prints a text file, found by its runfiles path.
///
/// `flutter_android_maven` generates the file; running its `maven_artifacts`
/// target shows it. Usage: `print_report <rlocation path>`.
import 'dart:io';

import 'package:runfiles/runfiles.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: print_report <runfiles path>');
    exit(2);
  }
  final path = Runfiles.create().rlocation(args.single);
  stdout.write(File(path).readAsStringSync());
}
