"""A repository whose fetch fails: no outline stripper matches the SDK's Dart."""

def _impl(repository_ctx):
    fail((
        "--@rules_dart//dart:outline_kernel is on, and the engine {reason} bundles a Dart SDK that rules_dart has no outline stripper for: " +
        "the stripper must be built from the same Dart release as the compiler, and " +
        "rules_dart pins the source of released Dart SDKs only. Build with " +
        "--@rules_dart//dart:outline_kernel=false."
    ).format(reason = repository_ctx.attr.reason))

kernel_outline_unavailable_repo = repository_rule(
    implementation = _impl,
    doc = "Stands in for the outline stripper of an SDK that has none, and fails, naming the flag that turns outlines off.",
    attrs = {
        "reason": attr.string(mandatory = True, doc = "Why the engine's Dart has no stripper, for the error."),
    },
)
