"""One property of `parse_gradle_maven_dependencies`, checked on many Gradle scripts.

The property, from the function's own contract ("a dependency the parser
cannot read is never silently lost"): every Maven coordinate a Gradle script
declares as a dependency is accounted for. It is either read (in `deps`) or
reported (in a line of `errors`). Reading it wrongly is a different failure,
covered by `android_plugin_maven_test.bzl`; what this guards is a dependency
that is in neither list, which compiles without it and fails at javac far from
the cause.

Cases are scripts with the coordinates (`group:artifact`) they declare. Where
the reader is line based, the cases are the forms a line-based reader is most
likely to mishandle: more than one statement on a line, a block opened and
closed on the line, a call form instead of a configuration name.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:android_plugin_maven.bzl",
    "parse_gradle_maven_dependencies",
)

def _accounted_for_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_gradle_maven_dependencies(ctx.attr.script)
    read = [d.group + ":" + d.artifact for d in result.deps]
    for coordinate in ctx.attr.coordinates:
        reported = [line for line in result.errors if coordinate in line]
        asserts.true(
            env,
            coordinate in read or reported,
            ("{coordinate} is declared by this script and the reader neither " +
             "read it nor reported its line.\nread: {read}\nreported: {errors}\n" +
             "script:\n{script}").format(
                coordinate = coordinate,
                read = read,
                errors = result.errors,
                script = ctx.attr.script,
            ),
        )
    return unittest.end(env)

_accounted_for_test = unittest.make(
    _accounted_for_impl,
    attrs = {
        "coordinates": attr.string_list(mandatory = True),
        "script": attr.string(mandatory = True),
    },
)

def gradle_dependency_cases(name, cases):
    """One test per case, and a suite named `name` of all of them.

    Args:
        name: The suite's name.
        cases: A dict of case name to `(script, [coordinate, ...])`.
    """
    tests = []
    for case, (script, coordinates) in cases.items():
        test_name = "{}_{}".format(name, case)
        _accounted_for_test(
            name = test_name,
            script = script,
            coordinates = coordinates,
        )
        tests.append(test_name)
    native.test_suite(name = name, tests = tests)
