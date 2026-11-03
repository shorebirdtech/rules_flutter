"""Gradle dependency forms the reader accounts for today.

See `gradle_dependency_check.bzl` for the property. These are the forms it
already holds for: they pin the behaviour a fix for the forms in
`gradle_dependency_gaps_test.bzl` must keep, and show the check can pass.
"""

load(":gradle_dependency_check.bzl", "gradle_dependency_cases")

def gradle_dependency_forms_test_suite(name):
    gradle_dependency_cases(name, {
        "groovy_single_quotes": (
            "dependencies {\n    implementation 'a.b:c:1.0'\n}\n",
            ["a.b:c"],
        ),
        "kotlin_parentheses": (
            "dependencies {\n    implementation(\"a.b:c:1.0\")\n}\n",
            ["a.b:c"],
        ),
        "several_configurations_each_on_a_line": (
            "dependencies {\n    api 'a.b:c:1.0'\n    compileOnly 'd.e:f:2.0'\n    runtimeOnly(\"g.h:i:3.0\")\n}\n",
            ["a.b:c", "d.e:f", "g.h:i"],
        ),
        "inside_a_block_opened_on_an_earlier_line": (
            "dependencies {\n    if (flag) {\n        implementation 'a.b:c:1.0'\n    }\n}\n",
            ["a.b:c"],
        ),
        "two_statements_joined_by_a_semicolon": (
            "dependencies {\n    implementation 'a.b:c:1.0'; implementation 'd.e:f:2.0'\n}\n",
            ["a.b:c", "d.e:f"],
        ),
        "a_version_the_reader_cannot_resolve": (
            "dependencies {\n    implementation \"a.b:c:$unknownVersion\"\n}\n",
            ["a.b:c"],
        ),
    })
