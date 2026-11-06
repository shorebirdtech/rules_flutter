"""How the repositories `flutter.pub()` makes find each other.

There is one repository per package for the whole build, however many hubs
(`flutter.pub(name = ...)`) list it. A built package (a hosted package, or a
Flutter SDK package other than `package:flutter`, which `flutter_pub_package`
builds from the pinned Flutter source) is two repositories, made by the one
module extension:

* its source repository, `flutter_pub__<package>` (`flutter_pub_package`): the
  package's files, its `flutter_pub_member` (or rules_dart's
  `pub_package_member`) and the facts it states about itself, which need
  nothing but its own archive;
* its library repository, `flutter_pub_lib__<package>` (`flutter_pub_library_repo`):
  the package's dependency cycle as one library, in the repository of the
  cycle's first package by name, which the others alias.

`package:flutter` (`flutter_framework_package`), the stub for a lock entry
nothing supplies, and a package `flutter.pub(resolve = ...)` maps to a workspace
target (`flutter_resolved_package`) are each one repository named
`flutter_pub__<package>`, which is its own library.

Library repositories read what source repositories record (their pubspec
dependencies, and `MEMBER_FILE`), which is why the source repositories read
nothing of each other: planning a cycle never asks a repository to wait on
itself. Both are read through canonical names, since Bazel fetches every
repository a label attribute names before the rule runs and only the packages
a cycle reaches are wanted.

What every repository needs to know of the lock, and would otherwise state in
an attribute of its own (growing the lock's record of the repositories with
the square of the package count), is stated once in the one index
repository, over every lock of the build. A hub is only the set of aliases a
user's own lock names.
"""

# What the repositories of the build are named by. No hub name is part of them,
# so a hub cannot be named with this prefix.
SPOKE_PREFIX = "flutter_pub"

# The one index repository, and the build-wide repositories beside the packages.
INDEX_REPO = "flutter_pub_index"
ANDROID_MAVEN_REPO = "flutter_pub_android_maven"
GOLDENS_REPO = "flutter_pub_goldens"

# The file each source repository writes: what its library repository needs to
# build the package with the others of its cycle.
MEMBER_FILE = "flutter_pub_member.json"

# What kind of member a source repository holds.
MEMBER_DART = "dart"  # rules_dart's `pub_package_member`
MEMBER_FLUTTER = "flutter"  # `flutter_pub_member`
MEMBER_OVERLAY = "overlay"  # an overlay's whole BUILD file, which `:<package>` is

_INDEX_FILE = "index.json"

def source_repo(package):
    """The name of the repository holding a package's files."""
    return "{}__{}".format(SPOKE_PREFIX, package)

def library_repo(package):
    """The name of the repository holding a built package's library."""
    return "{}_lib__{}".format(SPOKE_PREFIX, package)

def _canonical_prefix(ctx):
    """What canonical names of the extension's repositories start with, seen from `ctx`."""
    return ctx.name[:len(ctx.name) - len(ctx.original_name)]

def sibling_path(ctx, repo, path):
    """The path of a file at the root of another repository of the same module extension.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The other repository's name, as the extension gave it.
      path: A file at its root.

    Returns:
      Its path.
    """
    return ctx.path(Label("@@{}{}//:{}".format(_canonical_prefix(ctx), repo, path)))

def read_sibling_file(ctx, repo, path):
    """Reads a file of another repository of the same module extension.

    Args:
      ctx: The reading repository's `repository_ctx`.
      repo: The other repository's name, as the extension gave it.
      path: A file at its root.

    Returns:
      The file's text.
    """
    return ctx.read(sibling_path(ctx, repo, path))

def read_index(ctx):
    """The index: which packages the locks list, by who supplies them.

    Args:
      ctx: The reading repository's `repository_ctx`.

    Returns:
      `struct(built, other)`: `built`, a dict of the names of the built
      packages (hosted ones and Flutter SDK ones built from the Flutter
      source; each has a library repository); `other`, a dict of the names of
      the locks' other entries (`package:flutter`, packages mapped to a
      workspace target, and entries nothing supplies), whose `flutter_pub__<name>`
      repository is the library.
    """
    index = json.decode(read_sibling_file(ctx, INDEX_REPO, _INDEX_FILE))
    return struct(
        built = {n: True for n in index["built"]},
        other = {n: True for n in index["other"]},
    )

def library_label(index, package):
    """The label of a locked package's library, as another package depends on it.

    Args:
      index: The index, from `read_index`.
      package: A package of the locks.

    Returns:
      The label string.
    """
    repo = library_repo(package) if package in index.built else source_repo(package)
    return "@{}//:{}".format(repo, package)

def _flutter_pub_index_impl(ctx):
    ctx.file("BUILD.bazel", "")
    ctx.file(_INDEX_FILE, json.encode({
        "built": ctx.attr.built,
        "other": ctx.attr.other,
    }))
    return ctx.repo_metadata(reproducible = True)

flutter_pub_index = repository_rule(
    implementation = _flutter_pub_index_impl,
    attrs = {
        "built": attr.string_list(doc = "The locks' built packages, hosted and from the Flutter source: each has a source and a library repository."),
        "other": attr.string_list(doc = "The locks' other entries: `package:flutter`, packages mapped to workspace targets, and entries nothing supplies."),
    },
    doc = "The packages the repositories of every `flutter.pub()` lock plan against.",
)
