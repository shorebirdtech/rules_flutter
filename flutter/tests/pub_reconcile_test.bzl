"""Unit tests for reconciling a package that several `flutter_pub.from_lock()` locks list.

There is one repository per package for the whole build, so locks that list the
same package must agree on it. Every case here is a disagreement that must fail
when the module is read, naming both locks and what to do.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:lock_entry_kind.bzl", "FLUTTER_SOURCE", "GIT", "HOSTED", "UNSUPPORTED")
load("//flutter/private:pub_reconcile.bzl", "pub_command", "reconcile_package", "sdk_pin_errors", "unsupported_locks", "version_conflict_fix")

def _dir(lock):
    return lock.split("//")[1].split(":")[0]

def _hosted(version, hub = "deps", lock = "//app:pubspec.lock", sha256 = "aa", url = "https://pub.dev", on_version_conflict = "error"):
    return struct(kind = HOSTED, version = version, sha256 = sha256, url = url, hub = hub, lock_label = lock, lock_dir = _dir(lock), on_version_conflict = on_version_conflict)

def _git(ref, hub = "deps", lock = "//app:pubspec.lock", url = "https://github.com/x/foo.git", path = ".", git_lock = ""):
    return struct(kind = GIT, version = "1.0.0", git_url = url, resolved_ref = ref, git_path = path, git_lock = git_lock, hub = hub, lock_label = lock)

def _mentions(env, text, fragments):
    for fragment in fragments:
        asserts.true(env, fragment in text, "{} not in {}".format(fragment, text))

def _one_lock_is_its_own_entry_test_impl(ctx):
    env = unittest.begin(ctx)

    entry = _hosted("1.2.0")
    r = reconcile_package("meta", [entry])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, entry, r.entry)

    return unittest.end(env)

one_lock_is_its_own_entry_test = unittest.make(_one_lock_is_its_own_entry_test_impl)

def _locks_that_agree_share_the_package_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [
        _hosted("1.2.0"),
        _hosted("1.2.0", hub = "tools", lock = "@rules_flutter//:pubspec.lock"),
    ])
    asserts.equals(env, [], r.errors)
    asserts.equals(env, "1.2.0", r.entry.version)

    pinned = "0123456789abcdef0123456789abcdef01234567"
    r = reconcile_package("foo", [_git(pinned), _git(pinned, hub = "tools", lock = "//tools:pubspec.lock")])
    asserts.equals(env, [], r.errors)

    return unittest.end(env)

locks_that_agree_share_the_package_test = unittest.make(_locks_that_agree_share_the_package_test_impl)

def _the_runner_command_names_the_lock_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- get", pub_command("get", ""))
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- get --directory=apps/a", pub_command("get", "apps/a"))
    asserts.equals(env, "bazel run @rules_flutter//flutter/pub -- upgrade --directory=a meta intl", pub_command("upgrade", "a", ["meta", "intl"]))
    return unittest.end(env)

the_runner_command_names_the_lock_test = unittest.make(_the_runner_command_names_the_lock_test_impl)

def _a_lower_version_at_error_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [
        _hosted("1.18.0"),
        _hosted("1.19.0", hub = "dev_tool_deps", lock = "@rules_flutter//:pubspec.lock", on_version_conflict = "upgrade"),
    ])
    asserts.equals(env, None, r.entry)
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], [
        "\"meta\" has conflicting versions",
        "1.18.0 (hub \"deps\", //app:pubspec.lock, on_version_conflict = \"error\")",
        "1.19.0 (hub \"dev_tool_deps\", @rules_flutter//:pubspec.lock, on_version_conflict = \"upgrade\")",
        "the highest a lock records",
        "//app:pubspec.lock pins a lower one",
    ])
    fix = version_conflict_fix(r.behind)
    _mentions(env, fix, [
        "from the root of the workspace that holds it",
        "\n       bazel run @rules_flutter//flutter/pub -- upgrade --directory=app meta\n",
        "on_version_conflict = \"upgrade\"",
        "constraints forbid the higher versions",
    ])

    # A lock at the workspace root needs no directory; two locks behind get a
    # command each.
    r = reconcile_package("meta", [
        _hosted("1.18.0", lock = "//:pubspec.lock"),
        _hosted("1.18.0", hub = "b", lock = "//b/c:pubspec.lock"),
        _hosted("1.19.0", hub = "tools", lock = "//tools:pubspec.lock"),
    ])
    fix = version_conflict_fix(r.behind)
    _mentions(env, fix, [
        "\n       bazel run @rules_flutter//flutter/pub -- upgrade meta\n",
        "\n       bazel run @rules_flutter//flutter/pub -- upgrade --directory=b/c meta\n",
        "holds each",
    ])

    # A lock behind on several packages gets one command naming all of them.
    behind = []
    for name in ["vector_math", "meta", "collection"]:
        behind.extend(reconcile_package(name, [
            _hosted("1.18.0", lock = "//app:pubspec.lock"),
            _hosted("1.19.0", hub = "tools", lock = "//tools:pubspec.lock"),
        ]).behind)
    fix = version_conflict_fix(behind)
    _mentions(env, fix, ["\n       bazel run @rules_flutter//flutter/pub -- upgrade --directory=app collection meta vector_math\n"])
    asserts.equals(env, 1, fix.count("upgrade --directory=app"))

    return unittest.end(env)

a_lower_version_at_error_is_refused_test = unittest.make(_a_lower_version_at_error_is_refused_test_impl)

def _the_highest_version_wins_at_upgrade_test_impl(ctx):
    env = unittest.begin(ctx)

    low = _hosted("1.18.0", on_version_conflict = "upgrade")
    high = _hosted("1.19.0", hub = "tools", lock = "//tools:pubspec.lock")
    for entries in [[low, high], [high, low]]:
        r = reconcile_package("meta", entries)
        asserts.equals(env, [], r.errors)
        asserts.equals(env, "1.19.0", r.entry.version)

    # Versions compare as versions, not as text; a release outranks its prerelease.
    r = reconcile_package("meta", [_hosted("1.9.0", on_version_conflict = "upgrade"), _hosted("1.10.0", hub = "b", lock = "//b:pubspec.lock")])
    asserts.equals(env, "1.10.0", r.entry.version)
    r = reconcile_package("meta", [_hosted("2.0.0-dev.1", on_version_conflict = "upgrade"), _hosted("2.0.0", hub = "b", lock = "//b:pubspec.lock")])
    asserts.equals(env, "2.0.0", r.entry.version)

    return unittest.end(env)

the_highest_version_wins_at_upgrade_test = unittest.make(_the_highest_version_wins_at_upgrade_test_impl)

def _every_lower_lock_at_error_is_named_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [
        _hosted("1.17.0", hub = "a", lock = "//a:pubspec.lock"),
        _hosted("1.18.0", hub = "b", lock = "//b:pubspec.lock", on_version_conflict = "upgrade"),
        _hosted("1.19.0", hub = "c", lock = "//c:pubspec.lock"),
    ])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["//a:pubspec.lock", "pins a lower one"])
    asserts.false(env, "//b:pubspec.lock pins" in r.errors[0], r.errors[0])

    return unittest.end(env)

every_lower_lock_at_error_is_named_test = unittest.make(_every_lower_lock_at_error_is_named_test_impl)

def _same_version_different_digest_is_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [_hosted("1.2.0", sha256 = "aa"), _hosted("1.2.0", hub = "b", lock = "//b:pubspec.lock", sha256 = "bb")])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["different digests", "aa", "bb", "//app:pubspec.lock", "//b:pubspec.lock"])

    return unittest.end(env)

same_version_different_digest_is_refused_test = unittest.make(_same_version_different_digest_is_refused_test_impl)

def _different_registries_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [_hosted("1.2.0"), _hosted("1.2.0", hub = "b", lock = "//b:pubspec.lock", url = "https://pub.example.com")])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["different registries", "https://pub.dev", "https://pub.example.com", "//b:pubspec.lock"])

    return unittest.end(env)

different_registries_are_refused_test = unittest.make(_different_registries_are_refused_test_impl)

def _different_sources_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    sdk = struct(kind = FLUTTER_SOURCE, version = "0.0.0", hub = "c", lock_label = "//c:pubspec.lock")
    for other in [_git("0123abc", hub = "tools", lock = "@rules_flutter//:pubspec.lock"), sdk]:
        r = reconcile_package("foo", [_hosted("1.2.0"), other])
        asserts.equals(env, 1, len(r.errors))
        _mentions(env, r.errors[0], ["\"foo\" comes from different sources", "hosted 1.2.0", "//app:pubspec.lock", other.lock_label, "`resolve`"])

    return unittest.end(env)

different_sources_are_refused_test = unittest.make(_different_sources_are_refused_test_impl)

def _different_commits_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("foo", [_git("0123abc"), _git("4567def", hub = "tools", lock = "//tools:pubspec.lock")])
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], ["\"foo\" is pinned to different git sources", "0123abc", "4567def", "//tools:pubspec.lock"])

    # The same commit of a different path is a different package source.
    r = reconcile_package("foo", [_git("0123abc"), _git("0123abc", path = "pkgs/foo")])
    asserts.equals(env, 1, len(r.errors))

    return unittest.end(env)

different_commits_are_refused_test = unittest.make(_different_commits_are_refused_test_impl)

def _unsupported_entries_name_every_lock_test_impl(ctx):
    env = unittest.begin(ctx)

    entries = [
        struct(kind = UNSUPPORTED, hub = "a", lock_label = "//b:pubspec.lock"),
        struct(kind = UNSUPPORTED, hub = "b", lock_label = "//a:pubspec.lock"),
    ]
    asserts.equals(env, [], reconcile_package("odd", entries).errors)
    asserts.equals(env, "//a:pubspec.lock, //b:pubspec.lock", unsupported_locks(entries))

    return unittest.end(env)

unsupported_entries_name_every_lock_test = unittest.make(_unsupported_entries_name_every_lock_test_impl)

_PINS = {"flutter_test": {"test_api": "0.7.12", "matcher": "0.12.20"}}

def _sdk_pins_hold_test_impl(ctx):
    env = unittest.begin(ctx)

    entries = {
        "flutter_test": [struct(kind = FLUTTER_SOURCE, hub = "deps", lock_label = "//app:pubspec.lock")],
        "test_api": [_hosted("0.7.12"), _hosted("0.7.12", hub = "tools", lock = "//tools:pubspec.lock", on_version_conflict = "upgrade")],
        "matcher": [_hosted("0.12.20")],
    }
    chosen = {name: es[0] for name, es in entries.items()}
    asserts.equals(env, [], sdk_pin_errors("3.47.9", _PINS, chosen, entries))

    # An SDK package no lock lists pins nothing, and a pinned package no lock
    # lists is not this check's concern.
    asserts.equals(env, [], sdk_pin_errors("3.47.9", _PINS, {"test_api": _hosted("0.7.13")}, {"test_api": [_hosted("0.7.13")]}))
    asserts.equals(env, [], sdk_pin_errors("3.47.9", _PINS, {"flutter_test": entries["flutter_test"][0]}, entries))

    return unittest.end(env)

sdk_pins_hold_test = unittest.make(_sdk_pins_hold_test_impl)

def _a_lock_cannot_move_a_package_past_an_sdk_pin_test_impl(ctx):
    env = unittest.begin(ctx)

    tool = _hosted("0.7.13", hub = "dev_tool_deps", lock = "@rules_flutter//:pubspec.lock", on_version_conflict = "upgrade")
    app = _hosted("0.7.12", on_version_conflict = "upgrade")
    entries = {
        "flutter_test": [struct(kind = FLUTTER_SOURCE, hub = "deps", lock_label = "//app:pubspec.lock")],
        "test_api": [app, tool],
        "matcher": [_hosted("0.12.20")],
    }
    chosen = {"flutter_test": entries["flutter_test"][0], "test_api": tool, "matcher": entries["matcher"][0]}
    errors = sdk_pin_errors("3.47.9", _PINS, chosen, entries)
    asserts.equals(env, 1, len(errors))
    _mentions(env, errors[0], [
        "\"flutter_test\" (Flutter 3.47.9)",
        "\"test_api\" at exactly 0.7.12",
        "would use 0.7.13",
        "hub \"dev_tool_deps\", @rules_flutter//:pubspec.lock",
        "re-resolve that lock",
    ])
    asserts.false(env, "matcher" in errors[0], errors[0])

    return unittest.end(env)

a_lock_cannot_move_a_package_past_an_sdk_pin_test = unittest.make(_a_lock_cannot_move_a_package_past_an_sdk_pin_test_impl)

def pub_reconcile_test_suite(name):
    unittest.suite(
        name,
        one_lock_is_its_own_entry_test,
        locks_that_agree_share_the_package_test,
        the_runner_command_names_the_lock_test,
        a_lower_version_at_error_is_refused_test,
        the_highest_version_wins_at_upgrade_test,
        every_lower_lock_at_error_is_named_test,
        same_version_different_digest_is_refused_test,
        different_registries_are_refused_test,
        different_sources_are_refused_test,
        different_commits_are_refused_test,
        unsupported_entries_name_every_lock_test,
        sdk_pins_hold_test,
        a_lock_cannot_move_a_package_past_an_sdk_pin_test,
    )
