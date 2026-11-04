"""Gradle dependency forms the reader loses without a word.

See `gradle_dependency_check.bzl` for the property. Each case is valid Gradle
that declares a dependency `parse_gradle_maven_dependencies` neither reads nor
reports, because it looks for a configuration name only at the start of a
line.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_package.bzl", "parse_gradle_android_namespace")
load(":gradle_dependency_check.bzl", "gradle_dependency_cases")

def _one_line_namespace_impl(ctx):
    env = unittest.begin(ctx)

    # The namespace is where the generated `R` class lives. A script that
    # declares it on one line has declared it, and the reader must not answer
    # "none" (which falls back to the pubspec's `package`, often another name).
    for script in [
        "android { namespace = \"dev.example.one\" }",
        "android { namespace \"dev.example.one\" }",
        "android{namespace='dev.example.one'}",
        "android { compileSdk = 34; namespace = \"dev.example.one\" }",
    ]:
        asserts.equals(
            env,
            "dev.example.one",
            parse_gradle_android_namespace(script),
            "namespace lost from: " + script,
        )
    return unittest.end(env)

_one_line_namespace_test = unittest.make(_one_line_namespace_impl)

def gradle_dependency_gaps_test_suite(name):
    gradle_dependency_cases(name + "_dependencies", {
        "block_opened_and_closed_on_one_line_groovy": (
            "dependencies { implementation 'a.b:c:1.0' }\n",
            ["a.b:c"],
        ),
        "block_opened_and_closed_on_one_line_kotlin": (
            "dependencies { implementation(\"a.b:c:1.0\") }\n",
            ["a.b:c"],
        ),
        "block_without_spaces": (
            "dependencies{implementation 'a.b:c:1.0'}\n",
            ["a.b:c"],
        ),
        "two_dependencies_in_a_one_line_block": (
            "dependencies { implementation 'a.b:c:1.0'; api 'd.e:f:2.0' }\n",
            ["a.b:c", "d.e:f"],
        ),
        "after_a_statement_that_is_not_a_dependency": (
            "dependencies {\n    println(\"x\"); implementation 'a.b:c:1.0'\n}\n",
            ["a.b:c"],
        ),
        "after_a_variable_definition": (
            "dependencies {\n    def v = \"1.0\"; implementation \"a.b:c:$v\"\n}\n",
            ["a.b:c"],
        ),
        "inside_a_condition_on_one_line": (
            "dependencies {\n    if (flag) { implementation 'a.b:c:1.0' }\n}\n",
            ["a.b:c"],
        ),
        "add_call": (
            "dependencies {\n    add(\"implementation\", \"a.b:c:1.0\")\n}\n",
            ["a.b:c"],
        ),
    })
    _one_line_namespace_test(name = name + "_namespace")
    native.test_suite(
        name = name,
        tests = [name + "_dependencies", name + "_namespace"],
    )
