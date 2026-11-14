// Extracts the release archive of a commit to `e2e/external_module/rules_flutter`.
//
//   bazel run //tools/consumer_archive [-- <revision>]
//
// What a consumer of the published module gets is `git archive` output, which
// `.gitattributes` trims (`release_prep.sh` builds it the same way): files the
// archive omits are files the module must not need. The revision is HEAD by
// default; changes not committed are not in it.
import 'dart:io';

Future<void> main(List<String> args) async {
  final repo = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (repo == null || args.length > 1) {
    stderr.writeln('usage: bazel run //tools/consumer_archive [-- <revision>]');
    exit(2);
  }
  final revision = args.isEmpty ? 'HEAD' : args.single;
  final destination = Directory('$repo/e2e/external_module/rules_flutter');
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  destination.createSync(recursive: true);

  final archive = await Process.start('git', [
    'archive',
    '--format=tar',
    revision,
  ], workingDirectory: repo);
  final extract = await Process.start('tar', [
    '-x',
    '-f',
    '-',
    '-C',
    destination.path,
  ]);
  archive.stderr.listen(stderr.add);
  extract.stderr.listen(stderr.add);
  archive.stdout.pipe(extract.stdin);
  final failed = await archive.exitCode != 0 || await extract.exitCode != 0;
  if (failed) {
    stderr.writeln('consumer_archive: could not extract $revision');
    exit(1);
  }
  stdout.writeln('extracted $revision to ${destination.path}');
}
