"""Builds targets with a version given on the command line, as a test's `data`.

`--@rules_flutter//flutter:build_name` and `build_number` replace every
application's version for a build. A test that reads that version from a built
bundle takes the bundle as `data` built with them, whatever flags the test is
run with.
"""

_BUILD_NAME = str(Label("//flutter:build_name"))
_BUILD_NUMBER = str(Label("//flutter:build_number"))

def _transition_impl(_settings, attr):
    return {
        _BUILD_NAME: attr.build_name,
        _BUILD_NUMBER: attr.build_number,
    }

_transition = transition(
    implementation = _transition_impl,
    inputs = [],
    outputs = [_BUILD_NAME, _BUILD_NUMBER],
)

def _impl(ctx):
    return [DefaultInfo(
        files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.targets]),
        runfiles = ctx.runfiles().merge_all([t[DefaultInfo].default_runfiles for t in ctx.attr.targets]),
    )]

version_build = rule(
    implementation = _impl,
    doc = """Forwards the files and runfiles of `targets`, built with
`--@rules_flutter//flutter:build_name=<build_name>` and
`--@rules_flutter//flutter:build_number=<build_number>`.""",
    attrs = {
        "build_name": attr.string(doc = "The `build_name` setting; empty leaves it unset."),
        "build_number": attr.string(doc = "The `build_number` setting; empty leaves it unset."),
        "targets": attr.label_list(
            cfg = _transition,
            mandatory = True,
            doc = "The targets to build with the version, such as a `flutter_macos_app`.",
        ),
    },
)
