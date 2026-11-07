"""Unit tests for mapping a lock's packages to workspace targets.

`flutter.pub(resolve = {...})` names the target that builds each `path` package
of the lock, and may name the target that replaces any other. These pure checks
run when the lock is read, so every case here is a mistake that must fail then,
naming the lock, the package and the fix.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_lock")
load("//flutter/private:pub_resolve.bzl", "path_package_dir", "resolve_errors")

_LOCK = Label("//apps/greeter:pubspec.lock")

def _path_entry(name, path, relative = "true", version = "1.0.0"):
    return """\
  {name}:
    dependency: "direct main"
    description:
      path: "{path}"
      relative: {relative}
    source: path
    version: "{version}"
""".format(name = name, path = path, relative = relative, version = version)

def _lock(entries):
    return "packages:\n" + "".join(entries) + "sdks:\n  dart: \">=3.0.0 <4.0.0\"\n"

def _errors(entries, resolve, lock = _LOCK):
    return resolve_errors(lock, "deps", parse_pubspec_lock(_lock(entries), str(lock)), resolve)

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _resolves_paths_relative_to_the_lock_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, "packages/greeting", path_package_dir("apps/greeter", "../../packages/greeting").dir)
    asserts.equals(env, "pkgs/foo", path_package_dir("", "pkgs/foo").dir)
    asserts.equals(env, "y", path_package_dir("", "./x/../y").dir)
    asserts.equals(env, "pkgs/foo", path_package_dir("app", "..\\pkgs\\foo").dir)
    asserts.equals(env, "apps/greeter", path_package_dir("apps/greeter", ".").dir)
    asserts.equals(env, "", path_package_dir("app", "..").dir)
    for r in [path_package_dir("app", "../.."), path_package_dir("", "..")]:
        asserts.equals(env, None, r.dir)
        asserts.true(env, r.error != None and r.error != "")

    return unittest.end(env)

def _an_exact_map_has_no_errors_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(env, [], _errors(
        [
            _path_entry("greeting", "../../packages/greeting"),
            # As YAML spells a Windows path in double quotes: each backslash doubled.
            _path_entry("tagline", "..\\\\..\\\\packages\\\\tagline"),
        ],
        {
            "greeting": Label("//packages/greeting"),
            "tagline": Label("//packages/tagline:tagline_lib"),
        },
    ))

    return unittest.end(env)

def _an_unmapped_path_package_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors([_path_entry("greeting", "../../packages/greeting")], {})
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], [
        "pubspec.lock",
        "\"greeting\"",
        "path \"../../packages/greeting\"",
        "flutter.pub(name = \"deps\")",
        "resolve",
        "\"greeting\": \"//packages/greeting:<target>\"",
    ])

    return unittest.end(env)

def _a_mapped_name_the_lock_lacks_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors([], {"ghost": Label("//packages/ghost")})
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], ["\"ghost\"", "does not list it", "pubspec.lock", "flutter.pub(name = \"deps\")", "resolve"])

    return unittest.end(env)

def _hosted_git_and_sdk_entries_may_be_mapped_test_impl(ctx):
    """A mapped hosted, git or sdk entry replaces the locked package, with no path checks."""
    env = unittest.begin(ctx)

    entries = [
        """\
  meta:
    dependency: "direct main"
    description:
      name: meta
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
""",
        """\
  forked:
    dependency: "direct main"
    description:
      path: "."
      ref: main
      resolved-ref: "0123456789012345678901234567890123456789"
      url: "https://example.invalid/forked.git"
    source: git
    version: "1.0.0"
""",
        """\
  flutter_test:
    dependency: "direct dev"
    description: flutter
    source: sdk
    version: "0.0.0"
""",
    ]

    # Any repository and Bazel package: the replacement is not at the lock's path.
    resolve = {
        "meta": Label("//third_party/meta"),
        "forked": Label("@@other+//fork:forked"),
        "flutter_test": Label("//anywhere:flutter_test"),
    }
    asserts.equals(env, [], _errors(entries, resolve))

    return unittest.end(env)

def _unmapped_hosted_entries_need_nothing_test_impl(ctx):
    env = unittest.begin(ctx)

    hosted = """\
  meta:
    dependency: "direct main"
    description:
      name: meta
      sha256: "00"
      url: "https://pub.dev"
    source: hosted
    version: "1.0.0"
"""
    asserts.equals(env, [], _errors([hosted], {}))

    return unittest.end(env)

def _a_mapped_path_entry_may_point_anywhere_test_impl(ctx):
    env = unittest.begin(ctx)

    # The map says where Bazel gets the package: the path is pub's concern, so
    # an absolute path, one out of the repository, a target in another module
    # or in another package are all accepted.
    for entry, label in [
        (_path_entry("greeting", "/abs/packages/greeting", relative = "false"), "//packages/greeting"),
        (_path_entry("greeting", "../../../../elsewhere/greeting"), "@@other+//:greeting"),
        (_path_entry("greeting", "../../packages/greeting"), "@@other+//packages/greeting"),
        (_path_entry("greeting", "../../packages/greeting"), "//packages/other:greeting"),
    ]:
        asserts.equals(env, [], _errors([entry], {"greeting": Label(label)}))

    return unittest.end(env)

def _every_mistake_is_reported_test_impl(ctx):
    env = unittest.begin(ctx)

    errors = _errors(
        [
            _path_entry("alpha", "../../packages/alpha"),
            _path_entry("beta", "../../packages/beta"),
        ],
        {"ghost": Label("//packages/ghost")},
    )
    asserts.equals(env, 3, len(errors))
    _mentions(env, errors[0], ["\"alpha\""])
    _mentions(env, errors[1], ["\"beta\""])
    _mentions(env, errors[2], ["\"ghost\""])

    return unittest.end(env)

_resolves_paths_relative_to_the_lock_test = unittest.make(_resolves_paths_relative_to_the_lock_test_impl)
_an_exact_map_has_no_errors_test = unittest.make(_an_exact_map_has_no_errors_test_impl)
_an_unmapped_path_package_is_refused_test = unittest.make(_an_unmapped_path_package_is_refused_test_impl)
_a_mapped_name_the_lock_lacks_is_refused_test = unittest.make(_a_mapped_name_the_lock_lacks_is_refused_test_impl)
_hosted_git_and_sdk_entries_may_be_mapped_test = unittest.make(_hosted_git_and_sdk_entries_may_be_mapped_test_impl)
_unmapped_hosted_entries_need_nothing_test = unittest.make(_unmapped_hosted_entries_need_nothing_test_impl)
_a_mapped_path_entry_may_point_anywhere_test = unittest.make(_a_mapped_path_entry_may_point_anywhere_test_impl)
_every_mistake_is_reported_test = unittest.make(_every_mistake_is_reported_test_impl)

def pub_resolve_test_suite(name):
    unittest.suite(
        name,
        _resolves_paths_relative_to_the_lock_test,
        _an_exact_map_has_no_errors_test,
        _an_unmapped_path_package_is_refused_test,
        _a_mapped_name_the_lock_lacks_is_refused_test,
        _hosted_git_and_sdk_entries_may_be_mapped_test,
        _unmapped_hosted_entries_need_nothing_test,
        _a_mapped_path_entry_may_point_anywhere_test,
        _every_mistake_is_reported_test,
    )
