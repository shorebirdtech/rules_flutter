"""The Flutter SDKs the `flutter` extension declared, for the `flutter_pub` extension.

The locks are another extension's (`flutter_pub`), so that a lock it refuses
fails the hubs and not the toolchains. The hubs still build each SDK's
framework packages, so that extension needs what this one decided about the
SDKs: each one's release and framework source. It reads them here, from
`sdks.json`, rather than from the toolchain tags it cannot see.
"""

def _flutter_sdks_repo_impl(ctx):
    ctx.file("BUILD.bazel", "")
    ctx.file(SDKS_FILE, ctx.attr.sdks)
    return ctx.repo_metadata(reproducible = True)

flutter_sdks_repo = repository_rule(
    implementation = _flutter_sdks_repo_impl,
    attrs = {
        "sdks": attr.string(
            doc = "JSON: each SDK's name to its `version` (empty when its " +
                  "framework and engine are both given) and `framework` (the " +
                  "canonical label of its `flutter_framework.json`, or empty).",
            mandatory = True,
        ),
    },
    doc = "Writes `sdks.json`, the SDKs `flutter.toolchain()` declared.",
)

SDKS_FILE = "sdks.json"

def encode_sdks(sdks):
    """`sdks` (structs by name, as the `flutter` extension holds them) as JSON."""
    return json.encode({
        name: {
            "version": sdk.version or "",
            "framework": str(sdk.framework) if sdk.framework else "",
        }
        for name, sdk in sdks.items()
    })

def decode_sdks(text):
    """The SDKs `encode_sdks` wrote, as structs with `name`, `version`, `framework`."""
    return {
        name: struct(
            name = name,
            version = fields["version"] or None,
            framework = Label(fields["framework"]) if fields["framework"] else None,
        )
        for name, fields in json.decode(text).items()
    }
