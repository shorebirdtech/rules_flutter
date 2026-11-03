"""A pub registry served from the packages under `//registry`.

`flutter.pub` resolves hosted packages from the URLs in a lock file, which
cannot name a directory of this checkout. This serves the directory instead,
as a `file:` URL, in the layout pub.dev has
(`packages/<name>/versions/<version>.tar.gz`), so the spokes that fetch it run
the same repository rule, `flutter_pub_package`, that a pub.dev package does.
"""

def _registry_impl(rctx):
    source = rctx.path(rctx.attr.anchor).dirname
    rctx.watch_tree(source)

    staging = rctx.path("staging")
    for package in source.readdir():
        if not package.is_dir:
            continue
        for version in package.readdir():
            rctx.execute(["mkdir", "-p", "staging/" + package.basename])
            result = rctx.execute(["cp", "-R", str(version), "staging/%s/%s" % (package.basename, version.basename)])
            if result.return_code != 0:
                fail("cp %s: %s" % (version, result.stderr))

    # The checksum of each archive goes to the spokes: without it a spoke whose
    # package changed would still be the one fetched before.
    checksums = {}
    for package in staging.readdir():
        for version in package.readdir():
            archive = "packages/%s/versions/%s.tar.gz" % (package.basename, version.basename)
            rctx.execute(["mkdir", "-p", "packages/%s/versions" % package.basename])
            result = rctx.execute(["tar", "-czf", archive, "-C", str(version), "."])
            if result.return_code != 0:
                fail("tar %s: %s" % (archive, result.stderr))
            checksums[package.basename] = rctx.download(
                url = "file://" + str(rctx.path(archive)),
                output = "checksummed",
            ).sha256
    rctx.delete(staging)
    rctx.delete("checksummed")
    rctx.file("BUILD.bazel", "")
    rctx.file("registry", "")
    rctx.file("checksums.json", json.encode(checksums))

pub_registry = repository_rule(
    implementation = _registry_impl,
    attrs = {
        "anchor": attr.label(
            doc = "A file in the directory that holds the packages.",
            allow_single_file = True,
            mandatory = True,
        ),
    },
)
