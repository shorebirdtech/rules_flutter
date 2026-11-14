"""The Swift packages Apple plugins depend on, built by rules_swift_package_manager.

A pub plugin's `Package.swift` can depend on other Swift packages:

    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),

`flutter build` resolves those with Xcode and records the versions in the app's
`Package.resolved`. rules_flutter reads such a file, named by
`flutter_pub.from_lock(swift_package_resolved = ...)`, and declares one of
rules_swift_package_manager's `swift_package` repositories per pin, from the pub
extension, so each package's BUILD file and the plugins' Apple libraries see
each other. A plugin's dependency on a product of such a package
(`.product(name: "FirebaseCore", package: "firebase-ios-sdk")`) is the
product's target in that repository (`swift_product_label`).

`bazel run @<hub>//swift:resolve` writes the file, resolving every Apple
plugin's package as Flutter's generated plugin package does
(`flutter_swift_resolve.bzl`).

Only an iOS or macOS build that links such a plugin fetches a package.
"""

load("@rules_swift_package_manager//swiftpkg:defs.bzl", "swift_package")

# The repository names its generated BUILD files use for the packages they
# depend on, which ours must be.
# buildifier: disable=bzl-visibility
load("@rules_swift_package_manager//swiftpkg/internal:bazel_repo_names.bzl", "bazel_repo_names")

# The repository that lists the declared packages: which repository each
# pinned package identity is, for the plugins' Apple repositories, and every
# repository name, for rules_swift_package_manager's own.
SWIFT_PACKAGES_REPO = "flutter_pub_swift_packages"
SWIFT_PACKAGES_FILE = "swift_packages.json"
PACKAGE_REPOS_FILE = "package_repos.json"

def swift_package_repo(identity):
    """The repository of the Swift package of `identity`, as rules_swift_package_manager names it."""
    return bazel_repo_names.from_identity(identity)

def swift_product_label(identity, product):
    """The label, in a sibling repository's BUILD file, of a package's library product."""
    return "@{}//:{}".format(swift_package_repo(identity), product)

def parse_package_resolved(content, path):
    """The pins of a `Package.resolved` (version 1, 2 or 3).

    Args:
        content: The file's text.
        path: Its path, for messages.

    Returns:
        A list of structs with `identity`, `kind`, `location`, `revision`
        and `version` ("" when the pin is a branch or a revision).
    """
    data = json.decode(content)
    version = data.get("version")
    if version == 1:
        # Version 1 nests the pins under `object` and names fields otherwise.
        pins = []
        for pin in data.get("object", {}).get("pins", []):
            location = pin.get("repositoryURL", "")
            identity = location.rstrip("/").rsplit("/", 1)[-1].lower()
            if identity.endswith(".git"):
                identity = identity[:-len(".git")]
            state = pin.get("state", {})
            pins.append(struct(
                identity = identity,
                kind = "remoteSourceControl",
                location = location,
                revision = state.get("revision", ""),
                version = state.get("version") or "",
            ))
        return pins
    if version not in (2, 3):
        fail("{}: Package.resolved version {} is not one rules_flutter reads (1, 2 or 3).".format(path, version))
    pins = []
    for pin in data.get("pins", []):
        state = pin.get("state", {})
        pins.append(struct(
            identity = pin.get("identity", ""),
            kind = pin.get("kind", ""),
            location = pin.get("location", ""),
            revision = state.get("revision", ""),
            version = state.get("version") or "",
        ))
    return pins

def merge_pins(resolved):
    """The pins of several `Package.resolved` files, which must agree.

    Args:
        resolved: A list of `(path, pins)`, `pins` as `parse_package_resolved` returns them.

    Returns:
        A dict of identity to pin. Fails when two files pin a package
        differently, or a pin is not of a git repository.
    """
    merged = {}
    where = {}
    for path, pins in resolved:
        for pin in pins:
            if pin.kind != "remoteSourceControl":
                fail((
                    "{path}: the Swift package `{id}` is a {kind} pin; rules_flutter builds " +
                    "only packages from git repositories (`.package(url:)`)."
                ).format(path = path, id = pin.identity, kind = pin.kind or "malformed"))
            if not pin.revision:
                fail("{}: the Swift package `{}` has no revision. Resolve it again.".format(path, pin.identity))
            other = merged.get(pin.identity)
            if other and (other.revision != pin.revision or other.location != pin.location):
                fail((
                    "The Swift package `{id}` is pinned differently by {a} ({ra}) and {b} ({rb}). " +
                    "One build has one version of each package: resolve them together."
                ).format(id = pin.identity, a = where[pin.identity], ra = other.version or other.revision, b = path, rb = pin.version or pin.revision))
            merged[pin.identity] = pin
            where[pin.identity] = path
    return merged

def _flutter_swift_packages_impl(ctx):
    ctx.file(SWIFT_PACKAGES_FILE, json.encode({
        "packages": ctx.attr.packages,
        "resolved": ctx.attr.resolved,
    }))
    ctx.file(PACKAGE_REPOS_FILE, json.encode({"repo_names": sorted(ctx.attr.packages.values())}))
    ctx.file("BUILD.bazel", 'exports_files(["{}", "{}"])\n'.format(SWIFT_PACKAGES_FILE, PACKAGE_REPOS_FILE))
    return ctx.repo_metadata(reproducible = True)

flutter_swift_packages = repository_rule(
    implementation = _flutter_swift_packages_impl,
    attrs = {
        "packages": attr.string_dict(doc = "Each pinned package identity's repository."),
        "resolved": attr.string_list(doc = "The `Package.resolved` files read, for messages."),
    },
    doc = "Lists the Swift packages the pub extension declares. See the module docstring.",
)

def declare_swift_packages(module_ctx, resolved_labels):
    """Declares a repository per pin of the `Package.resolved` files, and their list.

    Args:
        module_ctx: The pub extension's `module_ctx`.
        resolved_labels: The `swift_package_resolved` labels of the tags.
    """
    resolved = []
    for label in resolved_labels:
        resolved.append((str(label), parse_package_resolved(module_ctx.read(label), str(label))))
    pins = merge_pins(resolved)
    package_repos = "@{}//:{}".format(SWIFT_PACKAGES_REPO, PACKAGE_REPOS_FILE)
    for identity, pin in sorted(pins.items()):
        name = swift_package_repo(identity)
        swift_package(
            name = name,
            bazel_package_name = name,
            commit = pin.revision,
            remote = pin.location,
            version = pin.version,
            dependencies_index = None,
            package_repos = package_repos,
        )
    flutter_swift_packages(
        name = SWIFT_PACKAGES_REPO,
        packages = {identity: swift_package_repo(identity) for identity in pins},
        resolved = [str(label) for label in resolved_labels],
    )
