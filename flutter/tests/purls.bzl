"""The package metadata a target's closure carries, as an SBOM tool reads it.

`package_metadata_files` collects the metadata file of each `package_metadata`
attached to a target in its deps' closure through each target's
`package_metadata` attribute (which a repository's `REPO.bazel` fills), as
supply-chain's own aspect does. `fetched_purls_test.dart` reads the purls in
them.
"""

load("@package_metadata//providers:package_metadata_info.bzl", "PackageMetadataInfo")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

_MetadataFilesInfo = provider(doc = "The package metadata files of a closure.", fields = ["files"])

_EDGES = ["deps", "members", "exports", "plugin_libs"]

def _metadata_aspect_impl(_target, ctx):
    direct = [m[PackageMetadataInfo].metadata for m in getattr(ctx.rule.attr, "package_metadata", []) if PackageMetadataInfo in m]
    transitive = []
    for dep in rule_attr_targets(ctx.rule.attr, _EDGES):
        if _MetadataFilesInfo in dep:
            transitive.append(dep[_MetadataFilesInfo].files)
    return [_MetadataFilesInfo(files = depset(direct, transitive = transitive))]

_metadata_aspect = aspect(
    implementation = _metadata_aspect_impl,
    attr_aspects = _EDGES,
)

def _impl(ctx):
    files = depset(transitive = [d[_MetadataFilesInfo].files for d in ctx.attr.deps])
    return [DefaultInfo(files = files, runfiles = ctx.runfiles(transitive_files = files))]

package_metadata_files = rule(
    implementation = _impl,
    doc = "The package metadata files of the closure of `deps`, as data for a test that reads them.",
    attrs = {"deps": attr.label_list(mandatory = True, aspects = [_metadata_aspect])},
)
