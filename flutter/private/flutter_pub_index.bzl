"""How the repositories of one `flutter.pub()` hub find each other.

A built package (a hosted package, or a Flutter SDK package other than
`package:flutter`, which `flutter_pub_package` builds from the pinned Flutter
source) is two repositories, made by the one module extension:

* its source repository, `<hub>__<package>` (`flutter_pub_package`): the
  package's files, its `flutter_pub_member` (or rules_dart's
  `pub_package_member`) and the facts it states about itself, which need
  nothing but its own archive;
* its library repository, `<hub>_lib__<package>` (`flutter_pub_library_repo`):
  the package's dependency cycle as one library, in the repository of the
  cycle's first package by name, which the others alias.

`package:flutter` (`flutter_framework_package`), and the stub for a lock entry
nothing supplies, is one repository named `<hub>__<package>` and is its own
library.

Library repositories read what source repositories record (their pubspec
dependencies, and `MEMBER_FILE`), which is why the source repositories read
nothing of each other: planning a cycle never asks a repository to wait on
itself. Both are read through canonical names, since Bazel fetches every
repository a label attribute names before the rule runs and only the packages
a cycle reaches are wanted.

What every repository needs to know of the lock, and would otherwise state in
an attribute of its own (growing the lock's record of the repositories with
the square of the package count), is stated once in the hub's index
repository.
"""

# The file each source repository writes: what its library repository needs to
# build the package with the others of its cycle.
MEMBER_FILE = "flutter_pub_member.json"

# What kind of member a source repository holds.
MEMBER_DART = "dart"  # rules_dart's `pub_package_member`
MEMBER_FLUTTER = "flutter"  # `flutter_pub_member`
MEMBER_OVERLAY = "overlay"  # an overlay's whole BUILD file, which `:<package>` is

_INDEX_FILE = "index.json"

def source_repo(hub, package):
    """The name of the repository holding a package's files."""
    return "{}__{}".format(hub, package)

def library_repo(hub, package):
    """The name of the repository holding a built package's library."""
    return "{}_lib__{}".format(hub, package)

def index_repo(hub):
    """The name of the hub's index repository."""
    return "{}_index".format(hub)

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

def read_index(ctx, hub):
    """The hub's index: which packages the lock lists, by who supplies them.

    Args:
      ctx: The reading repository's `repository_ctx`.
      hub: The hub's name.

    Returns:
      `struct(built, other)`: `built`, a dict of the names of the built
      packages (hosted ones and Flutter SDK ones built from the Flutter
      source; each has a library repository); `other`, a dict of the names of
      the lock's other entries (`package:flutter`, and entries nothing
      supplies), whose `<hub>__<name>` repository is the library.
    """
    index = json.decode(read_sibling_file(ctx, index_repo(hub), _INDEX_FILE))
    return struct(
        built = {n: True for n in index["built"]},
        other = {n: True for n in index["other"]},
    )

def library_label(hub, index, package):
    """The label of a locked package's library, as another package depends on it.

    Args:
      hub: The hub's name.
      index: The hub's index, from `read_index`.
      package: A package of the lock.

    Returns:
      The label string.
    """
    repo = library_repo(hub, package) if package in index.built else source_repo(hub, package)
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
        "built": attr.string_list(doc = "The lock's built packages, hosted and from the Flutter source: each has a source and a library repository."),
        "other": attr.string_list(doc = "The lock's other entries: `package:flutter`, and entries nothing supplies."),
    },
    doc = "The packages one `flutter.pub()` hub's repositories plan against.",
)
