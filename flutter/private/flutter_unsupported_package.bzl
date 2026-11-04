"""Spoke for a lock entry rules_flutter has no repository for.

A `pubspec.lock` lists packages from sources rules_flutter cannot provide: git
and path packages, and `sdk: flutter` packages outside the few the pinned
Flutter source supplies (`integration_test`, for one). A hub that failed to load
over such an entry would break every app that merely lists it, `integration_test`
in `dev_dependencies` being the usual case, even though nothing in Bazel uses it.

The hub therefore still lists the package. Its target is a stub that fails when
Bazel analyses something that depends on it, with a message naming the package,
where the lock got it from, and what to do. Nothing that does not depend on it is
affected.
"""

def _unsupported_package_impl(ctx):
    fail(ctx.attr.message)

unsupported_package = rule(
    implementation = _unsupported_package_impl,
    attrs = {
        "message": attr.string(mandatory = True),
    },
    doc = "A package target that fails analysis with `message`. See the file docstring.",
)

def unsupported_package_message(lock, package, source, provided_sdk_packages):
    """Why rules_flutter cannot provide a lock entry, and what to do about it.

    Args:
        lock: The lock file's label, for the message.
        package: The package name.
        source: The entry's `source:` in the lock.
        provided_sdk_packages: The Flutter SDK packages rules_flutter provides.

    Returns:
        The message.
    """
    if source == "sdk":
        advice = (
            "rules_flutter provides only the Flutter SDK packages {}. " +
            "Nothing in the build can use \"{}\" until it does; if only a test or tool " +
            "listed it, remove it from the pubspec and re-resolve the lock."
        ).format(", ".join(provided_sdk_packages), package)
    elif source == "git" or source == "path":
        advice = (
            "rules_flutter fetches hosted packages and the Flutter SDK packages, " +
            "not {} packages. Depend on a hosted release of \"{}\" and re-resolve the lock."
        ).format(source, package)
    else:
        advice = (
            "rules_flutter fetches hosted packages and the Flutter SDK packages, " +
            "not packages from a \"{}\" source. Depend on a hosted release of \"{}\" " +
            "and re-resolve the lock."
        ).format(source, package)
    return "package \"{}\" (source: {}) in {} cannot be built: {}".format(
        package,
        source,
        lock,
        advice,
    )

def _flutter_unsupported_package_impl(repository_ctx):
    package = repository_ctx.attr.package_name
    repository_ctx.file("BUILD.bazel", """\
load("@rules_flutter//flutter/private:flutter_unsupported_package.bzl", "unsupported_package")

unsupported_package(
    name = {name},
    message = {message},
    visibility = ["//visibility:public"],
)
""".format(name = repr(package), message = repr(repository_ctx.attr.message)))

    # The hub's Android aggregator depends on every spoke's `android:lib`. This
    # one contributes nothing: the failure belongs to the Dart target, which an
    # app that uses the package depends on.
    repository_ctx.file("android/BUILD.bazel", """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
""")

flutter_unsupported_package = repository_rule(
    implementation = _flutter_unsupported_package_impl,
    attrs = {
        "package_name": attr.string(mandatory = True),
        "message": attr.string(
            mandatory = True,
            doc = "What the package's target fails with (see `unsupported_package_message`).",
        ),
    },
    doc = "A hub spoke whose package target fails analysis; for lock entries rules_flutter cannot provide.",
)
