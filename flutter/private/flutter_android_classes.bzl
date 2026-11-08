"""Checks that no two jars an Android app links define one class differently.

`android_binary` puts every jar that reaches it into the app's deploy jar,
the classes it dexes, keeping the first copy of each class. When two jars
define a class differently (two versions of one library, or an old androidx
`-ktx` artifact whose classes moved into the main artifact) the app runs a
mix neither version is. Gradle resolves one version of each library and
aligns companion artifacts through their Gradle module metadata;
rules_jvm_external's resolution reads POMs only and does not. So
`flutter_android_app` puts this check on its `android_binary`: building the app
runs it, and a conflict fails the build naming both jars.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:utils.bzl", "PATH_MAPPING")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:exec_groups.bzl", "PORTABLE", "PORTABLE_EXEC_GROUPS", "portable_tools")
load("//flutter/private:rule_edges.bzl", "rule_attr_targets")

_MavenCoordinatesInfo = provider(
    doc = "The Maven coordinates of the rules_jvm_external targets below a library.",
    fields = {
        "coordinates": "depset of (label string, `group:artifact:version`) tuples.",
    },
)

_TAG = "maven_coordinates="

def _maven_coordinates_aspect_impl(target, ctx):
    own = [
        (str(target.label), tag[len(_TAG):].split("@")[0])
        for tag in getattr(ctx.rule.attr, "tags", [])
        if tag.startswith(_TAG)
    ]
    transitive = [
        dep[_MavenCoordinatesInfo].coordinates
        for dep in rule_attr_targets(ctx.rule.attr, ("deps", "exports", "runtime_deps"))
        if _MavenCoordinatesInfo in dep
    ]
    return [_MavenCoordinatesInfo(coordinates = depset(own, transitive = transitive))]

# rules_jvm_external tags each artifact's target with its coordinates, which a
# jar does not carry.
_maven_coordinates_aspect = aspect(
    implementation = _maven_coordinates_aspect_impl,
    attr_aspects = ["deps", "exports", "runtime_deps"],
)

def _origin(jar, coordinates):
    """What the message calls `jar`: its Maven coordinates, or its target."""
    label = str(jar.owner)
    return coordinates.get(label, label)

def _flutter_android_class_check_impl(ctx):
    infos = [lib[JavaInfo] for lib in ctx.attr.libraries if JavaInfo in lib]
    if not infos:
        return [CcInfo()]
    jars = java_common.merge(infos).transitive_runtime_jars
    coordinates = {}
    for lib in ctx.attr.libraries:
        for label, coordinate in lib[_MavenCoordinatesInfo].coordinates.to_list():
            coordinates[label] = coordinate

    stamp = ctx.actions.declare_file(ctx.label.name + ".validated")

    # Every path is an argument, so path mapping can rewrite it; the jars go
    # in a params file, since an app links hundreds.
    tool = ctx.actions.args()
    tool.add(ctx.file._tool)
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = True)
    args.set_param_file_format("multiline")
    args.add("--app", ctx.attr.app)
    args.add("--report", ctx.attr.report)
    args.add("--stamp", stamp)
    for jar in jars.to_list():
        args.add("--jar", jar)
        args.add(_origin(jar, coordinates))
    tools = portable_tools(ctx)
    ctx.actions.run(
        executable = tools.dart,
        arguments = [tool, args],
        inputs = depset(
            direct = [ctx.file._tool],
            transitive = [jars, tools.sdk_files.run],
        ),
        outputs = [stamp],
        mnemonic = "FlutterCheckAndroidClasses",
        exec_group = PORTABLE,
        execution_requirements = PATH_MAPPING,
        progress_message = "Checking the classes %{label} links",
    )

    # A dependency of the app's `android_binary` that links nothing: it is
    # there for the validation, which building the app runs.
    return [
        CcInfo(),
        OutputGroupInfo(_validation = depset([stamp])),
    ]

flutter_android_class_check = rule(
    implementation = _flutter_android_class_check_impl,
    attrs = {
        "app": attr.string(
            doc = "The label of the app, for the message.",
            mandatory = True,
        ),
        "libraries": attr.label_list(
            doc = "The Java and Android libraries of the app's `android_binary`.",
            aspects = [_maven_coordinates_aspect],
        ),
        "report": attr.string(
            doc = "The label of the app's `maven_artifacts` target, which the message points to.",
            mandatory = True,
        ),
        "_tool": attr.label(
            default = "//flutter/private/tools:check_android_classes.dart",
            allow_single_file = True,
        ),
    },
    exec_groups = PORTABLE_EXEC_GROUPS,
    doc = "Fails the build when two jars an Android app links define one class differently. A dependency of the app's `android_binary` that links nothing.",
)
