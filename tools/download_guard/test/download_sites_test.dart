import 'package:test/test.dart';

import '../download_sites.dart';

List<DownloadSite> sites(String source) => findDownloadSites('x.bzl', source);

void main() {
  group('findDownloadSites', () {
    test('accepts a call that passes a digest it was given', () {
      final s = sites('''
def _impl(ctx):
    ctx.download_and_extract(url = url, sha256 = ctx.attr.sha256, output = "o")
''');
      expect(s, hasLength(1));
      expect(s.single.callee, 'download_and_extract');
      expect(s.single.line, 2);
      expect(s.single.problem, isNull);
    });

    test('finds both call forms, with any receiver name', () {
      final s = sites('''
repository_ctx.download(url = a, sha256 = x, output = "a")
rctx.download_and_extract(url = b, sha256 = y)
''');
      expect(s.map((e) => e.callee), ['download', 'download_and_extract']);
      expect(s.every((e) => e.problem == null), isTrue);
    });

    test('flags a call with no digest', () {
      final s = sites('ctx.download(url = u, output = "o")');
      expect(s.single.problem, contains('no sha256'));
    });

    test('flags the empty string, in either quote', () {
      expect(
        sites('ctx.download_and_extract(url = u, sha256 = "")').single.problem,
        contains('empty sha256'),
      );
      expect(
        sites("ctx.download_and_extract(url = u, sha256 = '')").single.problem,
        contains('empty sha256'),
      );
    });

    test('flags every way an expression falls back to empty', () {
      for (final expr in [
        'checksums.get(path, "")',
        'ctx.attr.sha256s.get(path, "")',
        'ctx.attr.sha256 if ctx.attr.sha256 else ""',
        'ctx.attr.sha256 or ""',
      ]) {
        expect(
          sites('ctx.download(url = u, sha256 = $expr)').single.problem,
          contains('falls back to an empty sha256'),
          reason: expr,
        );
      }
    });

    test('leaves a digest that goes through another call to that call', () {
      for (final expr in [
        'require("a.zip", table.get(path, ""))',
        'require(x if x else "")',
      ]) {
        expect(
          sites('ctx.download(url = u, sha256 = $expr)').single.problem,
          isNull,
          reason: expr,
        );
      }
    });

    test('does not flag a lookup that fails on a missing key', () {
      final s = sites('ctx.download(url = u, sha256 = checksums[path])');
      expect(s.single.problem, isNull);
    });

    test('a comma in a later argument does not hide an empty digest', () {
      final s = sites('''
ctx.download(
    url = u,
    sha256 = "",
    output = "a,b",
)
''');
      expect(s.single.problem, contains('empty sha256'));
    });

    test('sees a digest argument that is not the last one', () {
      final s = sites('''
ctx.download(
    url = u,
    sha256 = digest,
    output = "o", # sha256 = "" in a comment
)
''');
      expect(s.single.digest, 'digest');
      expect(s.single.problem, isNull);
    });

    test('ignores calls in comments and strings', () {
      final s = sites('''
# ctx.download(url = u)
doc = """
ctx.download_and_extract(url = u)
"""
x = "ctx.download(url = u)"
''');
      expect(s, isEmpty);
    });

    test('reads a nested call as one argument', () {
      final s = sites('''
ctx.download(
    url = engine_artifact_url(rev, path),
    sha256 = lookup(path, default = "").get(path, "x"),
)
''');
      expect(s.single.digest, 'lookup(path, default = "").get(path, "x")');
      expect(s.single.problem, isNull);
    });

    test(
      'isPinned is true only for a digest that is the result of pinned()',
      () {
        bool pinned(String expr) =>
            sites('ctx.download(url = u, sha256 = $expr)').single.isPinned;
        expect(pinned('pinned("a.zip", ctx.attr.sha256)'), isTrue);
        expect(pinned('pinned(path, table.get(path, ""))'), isTrue);
        expect(pinned('pinned("a (x)", f(")"))'), isTrue);
        expect(pinned('ctx.attr.sha256'), isFalse);
        expect(pinned('checksums[path]'), isFalse);
        expect(pinned('require("a.zip", ctx.attr.sha256)'), isFalse);
        expect(pinned('pinned("a", x) or ""'), isFalse);
        expect(pinned('pinned("a", x) if y else z'), isFalse);
        expect(pinned('my_pinned("a", x)'), isFalse);
        expect(sites('ctx.download(url = u)').single.isPinned, isFalse);
      },
    );

    test('names the line of each call', () {
      final s = sites('a = 1\n\nctx.download(url = u, sha256 = "")\n');
      expect(s.single.where, 'x.bzl:3');
    });
  });
}
