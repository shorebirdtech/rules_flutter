"""Unit tests for reconciling a package that several `flutter.pub()` locks list.

There is one repository per package for the whole build, so locks that list the
same package must agree on it. Every case here is a disagreement that must fail
when the module is read, naming both locks and what to do.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:lock_entry_kind.bzl", "FLUTTER_SOURCE", "GIT", "HOSTED", "UNSUPPORTED")
load("//flutter/private:pub_reconcile.bzl", "reconcile_package", "unsupported_locks")

def _hosted(version, hub = "deps", lock = "//app:pubspec.lock", sha256 = "aa", url = "https://pub.dev"):
    return struct(kind = HOSTED, version = version, sha256 = sha256, url = url, hub = hub, lock_label = lock)

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

def _different_versions_are_refused_test_impl(ctx):
    env = unittest.begin(ctx)

    r = reconcile_package("meta", [
        _hosted("1.18.0"),
        _hosted("1.19.0", hub = "dev_tool_deps", lock = "@rules_flutter//:pubspec.lock"),
    ])
    asserts.equals(env, None, r.entry)
    asserts.equals(env, 1, len(r.errors))
    _mentions(env, r.errors[0], [
        "\"meta\" has different versions",
        "1.18.0",
        "1.19.0",
        "hub \"deps\"",
        "hub \"dev_tool_deps\"",
        "//app:pubspec.lock",
        "@rules_flutter//:pubspec.lock",
        "pub -- upgrade meta",
    ])

    return unittest.end(env)

different_versions_are_refused_test = unittest.make(_different_versions_are_refused_test_impl)

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

def pub_reconcile_test_suite(name):
    unittest.suite(
        name,
        one_lock_is_its_own_entry_test,
        locks_that_agree_share_the_package_test,
        different_versions_are_refused_test,
        same_version_different_digest_is_refused_test,
        different_registries_are_refused_test,
        different_sources_are_refused_test,
        different_commits_are_refused_test,
        unsupported_entries_name_every_lock_test,
    )
