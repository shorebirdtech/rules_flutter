"""The Material fonts a Flutter framework expects, as a repository.

The fonts are published by revision, and a framework says which it expects in
`bin/internal/material_fonts.version`. The pinned releases each name one, and
today one serves them all. For a framework that is not a release, the
revision is looked up in the revisions the pinned releases name, and downloaded
with the digest recorded for it; a revision no release names fails, naming it
and the attribute that pins it (`flutter.toolchain(material_fonts_sha256 = ...)`).
"""

load("//flutter/private:framework_source.bzl", "framework_root", "unset_message", "write_unset_stub")
load("//flutter/private:pinned.bzl", "pinned")
load("//flutter/private:versions.bzl", "ARTIFACT_CHECKSUMS", "FLUTTER_VERSIONS")

_FONTS_URL = "https://storage.googleapis.com/flutter_infra_release/flutter/fonts/{revision}/fonts.zip"

def _known_revisions():
    """The font revisions the pinned releases name, with the digest of each."""
    known = {}
    for version, meta in FLUTTER_VERSIONS.items():
        revision = meta.material_fonts_url.split("/")[-2]
        known[revision] = ARTIFACT_CHECKSUMS.get(version, {}).get("material_fonts.zip", "")
    return known

def _flutter_material_fonts_repo_impl(repository_ctx):
    known = _known_revisions()
    if repository_ctx.attr.framework_json:
        unset = unset_message(repository_ctx)
        if unset:
            write_unset_stub(repository_ctx, ["material-fonts/MaterialIcons-Regular.otf"], unset)
            return
        version_file = framework_root(repository_ctx).get_child("bin").get_child("internal").get_child("material_fonts.version")
        revision = repository_ctx.read(version_file).strip()
        sha256 = repository_ctx.attr.sha256 or known.get(revision, "")
        if not sha256:
            fail((
                "The framework expects Material fonts revision {revision} " +
                "(bin/internal/material_fonts.version), which no pinned Flutter release names. " +
                "Pin its digest with flutter.toolchain(material_fonts_sha256 = \"<sha256 of {url}>\")."
            ).format(revision = revision, url = _FONTS_URL.format(revision = revision)))
    else:
        meta = FLUTTER_VERSIONS[repository_ctx.attr.flutter_version]
        revision = meta.material_fonts_url.split("/")[-2]
        sha256 = known[revision]

    repository_ctx.download_and_extract(
        url = _FONTS_URL.format(revision = revision),
        sha256 = pinned("material_fonts.zip", sha256),
        output = "material-fonts",
    )
    repository_ctx.file(
        "BUILD.bazel",
        'exports_files(["material-fonts/MaterialIcons-Regular.otf"], visibility = ["//visibility:public"])\n',
    )

flutter_material_fonts_repo = repository_rule(
    _flutter_material_fonts_repo_impl,
    doc = "The Material fonts revision a Flutter framework expects.",
    attrs = {
        "flutter_version": attr.string(doc = "A pinned release whose fonts these are. Unused with `framework_json`."),
        "framework_json": attr.label(
            doc = "The `flutter_framework.json` of a framework source, whose `bin/internal/material_fonts.version` names the revision.",
            allow_single_file = True,
        ),
        "sha256": attr.string(doc = "The digest of the fonts archive, for a revision no pinned release names."),
    },
)
