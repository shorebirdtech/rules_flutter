"""flutter_pub_package — the `flutter pub get` analog for a single hosted
Flutter pub.dev package, a git package at its locked commit, or a Flutter SDK
package built from the pinned Flutter source.

For each such package in a Flutter app's pubspec.lock this rule:
  1. Downloads the same `pub.dev/api/packages/<name>/versions/<version>.tar.gz`
     archive, checked against `pubspec.lock`'s digest, that rules_dart's
     `pub_lock_package` would (through the shared `fetch_pub_archive`). A
     Flutter SDK package (`sdk: flutter` in the lock: `flutter_test`,
     `integration_test`, `flutter_driver`, ...) has no archive: with
     `flutter_source_version` set, its tree is `packages/<name>` of the
     toolchain's pinned Flutter source tarball, checked against that
     tarball's recorded digest. A git package (`source: git`) is fetched at the
     lock's `resolved-ref` by rules_dart's `fetch_pub_git`, which lays out its
     directory of the repository exactly as pub does. Everything after this
     step is the same.
  2. Reads the package's pubspec.yaml, as pub does (rules_dart's `read_pubspec`).
  3. Projects `flutter.plugin.platforms` via `flutter_plugin_block`.
  4. Scans the extracted package tree for per-platform Apple source layouts
     (modern SwiftPM `<platform>/<pkg>/Sources/<pkg>/`, shared-darwin
     `darwin/Classes/`, legacy `<platform>/Classes/`).
  5. Branches on what the pubspec declares:
       - Nothing of Flutter's → emit rules_dart's `pub_package_member`.
         Pure-Dart pub packages reach consumers exactly as they do under
         `pub.pub()`.
       - A `flutter.plugin` block, or fonts, assets, shaders or
         `uses-material-design` → emit a `flutter_pub_member`, a plugin whose
         `plugin_platforms_json` carries the parsed metadata when the block is
         there, plus per-platform sub-targets: `:<pkg>_apple_macos` /
         `:<pkg>_apple_ios` `flutter_apple_plugin_library` when Apple sources
         are detected for the corresponding `flutter.plugin.platforms.<plat>`
         entry.
  6. Records the names the pubspec depends on, and the kind of member this is
     (`flutter_pub_index.bzl`), for the package's library repository.

This repository is the package's *source*: its files and the facts it states
about itself. Its *library*, the target other packages depend on, is made by
`flutter_pub_library_repo` over the members of the package's dependency cycle,
which is why a member has no dependencies of its own.

This is the rules_flutter sibling of rules_dart's `pub_lock_package`. The two
rules never run for the same package: `flutter_pub.from_lock()` always invokes
this one for hosted pub packages; `pub.pub()` (in non-Flutter modules) keeps
using `pub_lock_package`. Both fetch and lay out the archive with rules_dart's
`fetch_pub_archive`, so one package version is the same tree whichever rule asks
for it.
"""

load("@rules_dart//dart/pub:pub_graph.bzl", "write_pubspec_dependencies")
load("@rules_dart//dart/pub:pub_lock_package.bzl", "fetch_pub_archive", "fetch_pub_git", "find_pub_license_file")
load("@rules_dart//dart/pub:pubspec.bzl", "read_pubspec")
load("//flutter/private:android_plugin_maven.bzl", "MAVEN_DEPS_FILE", "gradle_statements", "parse_gradle_maven_dependencies")
load("//flutter/private:artifact_urls.bzl", "flutter_source_tarball_url")
load("//flutter/private:framework_source.bzl", "check_dependency_constraints", "link_framework_package", "unset_message", "write_unset_stub")
load("//flutter/private:asset_variants.bzl", "variant_scale")
load("//flutter/private:cmake_link_libraries.bzl", "parse_cmake_link_libraries")
load("//flutter/private:flutter_pub_index.bzl", "MEMBER_DART", "MEMBER_FILE", "MEMBER_FLUTTER", "MEMBER_OVERLAY", "library_label", "owner_prefix", "read_index", "sibling_path", "source_repo")
load("//flutter/private:flutter_pubspec.bzl", "flutter_assets_block", "flutter_licenses_block", "flutter_manifest_errors", "flutter_plugin_block")
load("//flutter/private:pinned.bzl", "pinned")
load("//flutter/private:swiftpm_dependencies.bzl", "find_unsupported_swiftpm_dependencies")

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

# Kotlin/Java source extensions for Android plugin libraries.
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

def _has_files_under(ctx, relative_path, extensions = None):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions` (any file when `extensions` is None).
    `ctx.path(p).readdir()` is the documented repo-rule way to walk a
    directory; recursing in Starlark keeps the logic local instead of
    forking out to `find`.
    """
    root = ctx.path(relative_path)
    if not root.exists:
        return False

    stack = [root]
    for _ in range(10000):  # bound the walk; pub packages are not deep
        if not stack:
            break
        d = stack.pop()
        if not d.exists:
            continue
        for entry in d.readdir():
            if entry.is_dir:
                stack.append(entry)
            else:
                if extensions == None:
                    return True
                name = entry.basename
                ext = name.rsplit(".", 1)[-1] if "." in name else ""
                if ext in extensions:
                    return True
    return False

def _detect_apple_source_dirs(ctx, package_name, platform, shared_darwin_source):
    """List Apple source directory globs for the given platform.

    Returns the relative-to-package-root directories that contain Apple
    sources for `platform`. Empty list when no sources are detected.
    """
    candidates = []

    # Modern SwiftPM layout: <platform>/<pkg>/Sources/<pkg>/...
    swiftpm_dir = "{plat}/{pkg}/Sources/{pkg}".format(plat = platform, pkg = package_name)
    if _has_files_under(ctx, swiftpm_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(swiftpm_dir)

    # Shared darwin source layout: darwin/Classes/...
    if shared_darwin_source:
        darwin_dir = "darwin/Classes"
        if _has_files_under(ctx, darwin_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_dir)

        # Legacy darwin SwiftPM (older path_provider_foundation versions).
        darwin_swiftpm_dir = "darwin/{pkg}/Sources/{pkg}".format(pkg = package_name)
        if _has_files_under(ctx, darwin_swiftpm_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_swiftpm_dir)

    # Legacy split layout: <platform>/Classes/...
    legacy_dir = "{plat}/Classes".format(plat = platform)
    if _has_files_under(ctx, legacy_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(legacy_dir)

    return candidates

def _fail_on_swiftpm_dependencies(ctx, package_name, platform, shared_darwin_source):
    """Fails when a plugin's SwiftPM package depends on other Swift packages.

    Reads each `<platform>/<dir>/Package.swift` (and `darwin/<dir>/` for a
    shared darwin plugin). rules_flutter compiles the plugin's own sources and
    does not resolve other Swift packages, so a remote dependency would leave
    the app without code the plugin needs.
    """
    roots = [platform] + (["darwin"] if shared_darwin_source else [])
    for root in roots:
        root_path = ctx.path(root)
        if not root_path.exists:
            continue
        for entry in root_path.readdir():
            manifest = entry.get_child("Package.swift")
            if not entry.is_dir or not manifest.exists:
                continue
            unsupported = find_unsupported_swiftpm_dependencies(
                ctx.read(manifest),
                "%s/%s" % (root, entry.basename),
            )
            if unsupported:
                fail((
                    "package:{pkg} ({plat}) declares Swift package dependencies in " +
                    "{root}/{dir}/Package.swift that rules_flutter does not yet " +
                    "resolve (SwiftPM dependencies of plugins are not supported):\n" +
                    "{deps}"
                ).format(
                    pkg = package_name,
                    plat = platform,
                    root = root,
                    dir = entry.basename,
                    deps = "\n".join(["  - " + d for d in unsupported]),
                ))

def _detect_apple_include_dirs(ctx, source_dirs, package_name):
    """Collect SwiftPM-canonical public-header directories for the given Apple sources.

    SwiftPM's `publicHeadersPath: "include"` (the default) places public
    headers at `Sources/<Target>/include/[<Module>/]Foo.h` and adds the
    `include` directory to the lib's own header search path. Plugins
    relying on this convention `#import "Foo.h"` (bare basename) from
    sibling `.m` files; without an explicit `-I` flag clang can't find
    the header. Mirror SwiftPM by adding both `include` and the
    `include/<pkg>` nested subdirectory (when present) — covers
    headers placed directly under `include/` and the more common
    umbrella-style layout.
    """
    include_dirs = []
    for src_dir in source_dirs:
        include_root = src_dir + "/include"
        include_root_path = ctx.path(include_root)
        if include_root_path.exists:
            include_dirs.append(include_root)
            nested = include_root + "/" + package_name
            if ctx.path(nested).exists:
                include_dirs.append(nested)
    return include_dirs

def _detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; App Store submission walks the bundle for
    `*.xcprivacy` files and aggregates them into the app's privacy
    report. CocoaPods/SwiftPM bundle them automatically as framework
    resources; we mirror by collecting them here and threading them
    through to `flutter_apple_plugin_library`'s `privacy_manifests`
    attr (which forwards to the inner objc/swift_library `data`).

    Two layouts occur in real plugins:

    * **Pattern A** (e.g. `package_info_plus`, `share_plus`):
      `<source_dir>/PrivacyInfo.xcprivacy`.
    * **Pattern B** (e.g. `path_provider_foundation`, `record_ios`,
      `webview_flutter_wkwebview`):
      `<source_dir>/Resources/PrivacyInfo.xcprivacy`.

    Returns a sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def _detect_desktop_source_dir(ctx, platform):
    """Return the Linux/Windows source dir if it contains C/C++ files.

    Pub plugins put Linux sources at `linux/` and Windows sources at
    `windows/`. We surface a single source dir per platform (the
    plugin's own conventions); subdirectories like `linux/include/` are
    swept by the resulting glob.
    """
    if _has_files_under(ctx, platform, _DESKTOP_SRC_EXTENSIONS):
        return platform
    return ""

def _read_desktop_link_libraries(ctx, platform):
    """Parse the system libraries the plugin's `<platform>/CMakeLists.txt` links.

    Returns the result of `parse_cmake_link_libraries`: linker flags and the
    lines that could not be translated. Both are empty when the plugin ships no
    CMakeLists.txt. The errors are not raised here: they fail the build of the
    platform's runner, so a plugin that cannot be linked on Windows still
    builds everywhere else.
    """
    path = platform + "/CMakeLists.txt"
    p = ctx.path(path)
    if not p.exists:
        return parse_cmake_link_libraries("", platform, path)
    return parse_cmake_link_libraries(ctx.read(p), platform, path)

def _format_link_attrs(link):
    """The `linkopts` / `link_errors` attributes of a plugin library target."""
    attrs = ""
    if link.linkopts:
        attrs += "    linkopts = %s,\n" % repr(link.linkopts)
    if link.errors:
        attrs += "    link_errors = %s,\n" % repr(link.errors)
    return attrs

def _detect_android_source_dir(ctx):
    """Return the Android source dir if it contains Kotlin/Java files.

    Pub plugins use the standard Android directory layout
    `android/src/main/{kotlin,java}/`.
    """
    if _has_files_under(ctx, "android/src/main", _ANDROID_SRC_EXTENSIONS):
        return "android/src/main"
    return ""

def _detect_android_resources(ctx):
    """True when the plugin ships Android resources at `android/src/main/res/`.

    The standard AGP resource location. Detected resources are compiled
    into the generated `kt_android_library` via `resource_files` so the
    plugin's `R` class resolves and the resources merge into the
    consuming APK — same as any Gradle-built Android library.
    """
    return _has_files_under(ctx, "android/src/main/res")

def parse_gradle_android_namespace(content):
    """Extract `android.namespace` from a Gradle build script.

    Handles the AGP-8 assignment forms
    `namespace = 'com.example'` (Groovy) / `namespace = "com.example"`
    (Kotlin DSL) and the Groovy method-call form `namespace 'com.example'`.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.

    Returns:
        The declared namespace, or empty string when the script
        declares none.
    """
    for line in gradle_statements(content):
        if not line.startswith("namespace"):
            continue
        rest = line[len("namespace"):].strip()
        if rest.startswith("="):
            rest = rest[1:].strip()
        for quote in ("'", '"'):
            if rest.startswith(quote):
                end = rest.find(quote, 1)
                if end > 0:
                    return rest[1:end]
    return ""

def parse_android_manifest_package(content):
    """Extract the `package` attribute from an AndroidManifest.xml.

    The pre-AGP-8 way for a library to declare its namespace.

    Args:
        content: The AndroidManifest.xml file content.

    Returns:
        The `package` attribute of the `<manifest>` element, or empty
        string when the manifest carries none.
    """
    start = content.find("<manifest")
    if start < 0:
        return ""
    end = content.find(">", start)
    if end < 0:
        return ""
    tag = content[start:end]
    for quote in ('"', "'"):
        marker = "package=" + quote
        idx = tag.find(marker)
        if idx >= 0:
            close = tag.find(quote, idx + len(marker))
            if close >= 0:
                return tag[idx + len(marker):close]
    return ""

def _java_package_problem(name):
    """Why `name` is not a Java package name, or "".

    The namespace of a plugin is written into its generated `BuildConfig.java`,
    the manifest synthesized for a plugin with resources and the library's
    `custom_package`. It is read
    from the package's Gradle script or manifest, so it has to be a plain
    dotted name of identifiers before it goes anywhere near them.
    """
    for part in name.split("."):
        if not part:
            return "has an empty segment"
        for i, c in enumerate(part.elems()):
            letter = ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"
            digit = "0" <= c and c <= "9"
            if not (letter or (digit and i > 0)):
                return "has the character {} where a Java identifier has none".format(repr(c))
    return ""

def _checked_java_package(package, source, name):
    """Return the namespace `name`, or fail naming the package and its source."""
    problem = _java_package_problem(name) if name else ""
    if problem:
        fail("package {}: the Android namespace {} (from {}) is not a Java package name: it {}.".format(
            package,
            repr(name),
            source,
            problem,
        ))
    return name

def _android_gradle_script(ctx):
    """The plugin's Gradle build script: `android/build.gradle`, else its `.kts`.

    Gradle runs `build.gradle` when a project has both, so every reader of the
    script reads that one.

    Returns:
        The path, or `None` when the plugin has neither.
    """
    for filename in ("android/build.gradle", "android/build.gradle.kts"):
        p = ctx.path(filename)
        if p.exists:
            return p
    return None

def _detect_android_namespace(ctx):
    """Resolve the plugin's Android namespace the way AGP does.

    AGP determines a library's namespace from `android.namespace` in
    `build.gradle(.kts)`, falling back to the manifest's `package`
    attribute for pre-AGP-8 projects. The namespace is where the
    generated `R` and `BuildConfig` classes live, so resource
    references like `R.drawable.ic_mic` only resolve when we use the
    same one. Returns empty string when the plugin declares neither.
    """
    script = _android_gradle_script(ctx)
    if script:
        namespace = parse_gradle_android_namespace(ctx.read(script))
        if namespace:
            return namespace
    manifest_path = ctx.path("android/src/main/AndroidManifest.xml")
    if manifest_path.exists:
        return parse_android_manifest_package(ctx.read(manifest_path))
    return ""

def _detect_android_manifest(ctx):
    """Return the plugin's `android/src/main/AndroidManifest.xml` path if present.

    AGP's `ManifestMerger2` combines each Android library's manifest into
    the consuming app's final AndroidManifest.xml at build time. Plugins
    routinely declare `<activity>`, `<service>`, `<receiver>`,
    `<provider>`, `<uses-permission>`, and `<queries>` entries this way
    (e.g. url_launcher_android's WebViewActivity, record_android's
    RECORD_AUDIO permission). `rules_android`'s `android_binary` runs
    the equivalent merger over its dep graph; a `kt_android_library`
    (which extends `android_library`) participates if it sets
    `manifest = "..."`. Returns the path relative to the spoke root, or
    empty when the plugin ships no manifest.
    """
    if ctx.path("android/src/main/AndroidManifest.xml").exists:
        return "android/src/main/AndroidManifest.xml"
    return ""

def _detect_android_native_build(ctx):
    """True when the plugin's Gradle build compiles native code with the NDK.

    Gradle-built Flutter plugins declare `externalNativeBuild` in
    `android/build.gradle*` to compile C/C++ sources (CMake / ndk-build)
    into a shared library the APK must carry — e.g. package:jni's
    libdartjni.so. rules_flutter has no generic translation for those
    builds; packages that need one ship a curated overlay (bundled under
    `@rules_flutter//ext/` or user-supplied via `flutter_pub.plugin_overlays`).
    Detection lets the generated android/ sub-package fail loudly instead
    of silently producing an APK missing the library.
    """
    script = _android_gradle_script(ctx)
    return bool(script) and "externalNativeBuild" in ctx.read(script)

def _make_android_native_build_unsupported_content(package_name, version):
    """Generate an `android/BUILD.bazel` that fails at load time.

    Emitted for plugins whose Gradle build compiles native code for Android
    (externalNativeBuild) when no overlay provides a Bazel translation.
    An Android build that links the plugin loads this file through its
    member's `exports` and fails with a clear message; non-Android
    platforms never load it and are unaffected.
    """
    message = (
        "package:{pkg} {version} compiles native code for Android via " +
        "Gradle's externalNativeBuild, which rules_flutter cannot " +
        "translate automatically. An APK built without that library would " +
        "crash at plugin registration, so this is a hard error. Provide a " +
        "plugin overlay for {pkg} (flutter_pub.plugin_overlays in MODULE.bazel) " +
        "that compiles the package's native sources with cc_shared_library " +
        "and ships them through flutter_plugin.native_deps — see " +
        "@rules_flutter//ext/jni for the canonical example."
    ).format(pkg = package_name, version = version)
    return 'fail("' + message + '")\n'

def _parse_consumer_proguard_files(content):
    """Extract `consumerProguardFiles` paths from a Gradle build script.

    AGP plugins declare reflection-keep rules they need consumers to
    apply via:
      consumerProguardFiles 'consumer-rules.pro'         (Groovy)
      consumerProguardFiles "consumer-rules.pro"         (Groovy)
      consumerProguardFiles("consumer-rules.pro")        (Kotlin DSL)
    Multiple files per declaration are comma-separated. Returns a sorted,
    deduplicated list of paths. Permissive matching by design: false
    positives in comments / strings are filtered out by the existence
    check downstream.
    """
    paths = {}
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if "consumerProguardFiles" not in line:
            continue

        # Snip everything after the keyword and pull paths out of the
        # quoted segments. Supports both Groovy ('...') and Kotlin DSL
        # ("..."), and handles comma-separated multi-arg invocations.
        rest = line.split("consumerProguardFiles", 1)[1]
        for quote in ("'", '"'):
            idx = 0
            for _ in range(rest.count(quote) // 2):
                start = rest.find(quote, idx)
                if start < 0:
                    break
                end = rest.find(quote, start + 1)
                if end < 0:
                    break
                paths[rest[start + 1:end]] = True
                idx = end + 1
    return sorted(paths.keys())

def _detect_consumer_proguard_specs(ctx):
    """Find the plugin's `consumer-rules.pro` files, declared via Gradle.

    Reads `android/build.gradle` (or `android/build.gradle.kts`),
    parses `consumerProguardFiles` declarations, and returns paths
    relative to the spoke's `android/` sub-package — only for files
    that actually exist on disk. Empty when the plugin doesn't ship
    consumer rules. AGP propagates these into the consuming app's R8
    invocation; rules_android does the same when they appear in
    `kt_android_library(proguard_specs = [...])` and the binary has
    R8 enabled.
    """
    paths = []
    script = _android_gradle_script(ctx)
    if script:
        for relpath in _parse_consumer_proguard_files(ctx.read(script)):
            if ctx.path("android/" + relpath).exists:
                paths.append(_checked_file_name(
                    ctx.attr.package_name,
                    "consumerProguardFiles file",
                    relpath,
                ))
    return paths

def _read_plugin_maven_deps(ctx):
    """Parse the spoke's `android/build.gradle*` Maven dependencies.

    Reads the package's Gradle build file (`build.gradle`, else the `.kts`).
    Returns the parse result of `parse_gradle_maven_dependencies`: the declared
    dependencies and the lines it could not read. Both are empty when the
    package has no Gradle script.
    """
    script = _android_gradle_script(ctx)
    return parse_gradle_maven_dependencies(ctx.read(script) if script else "")

def _maven_dep_dicts(parsed):
    """The parsed dependencies as the dicts `maven_deps.json` records."""
    return [
        {
            "kind": d.kind,
            "coordinate": d.group + ":" + d.artifact,
            "version": d.version,
            "line": d.line,
        }
        for d in parsed.deps
    ]

def _write_maven_deps(ctx, deps, errors):
    """Record the Maven dependencies the Android check of the hub reads.

    Written for every spoke, so `@flutter_pub_android_maven` can read
    all of them: empty for a package that is not an Android plugin with
    sources. For a plugin whose `android/BUILD.bazel` an overlay supplies,
    the dependencies its Gradle build declares and no errors. At the root of
    the spoke, as a package with no Android library has no `android/` package.
    """
    ctx.file(MAVEN_DEPS_FILE, json.encode({
        "package": ctx.attr.package_name,
        "version": ctx.attr.version,
        "deps": deps,
        "errors": errors,
    }) + "\n")

def _glob_block(srcs_dirs, extensions):
    """Format a `glob([...])` expression covering the given extensions.

    Each directory in `srcs_dirs` is recursively swept for files matching
    any extension in `extensions`. `test/` and `example/` subtrees are
    excluded — pub plugins routinely ship integration tests next to
    their plugin source, but those should never be linked into the
    runner.

    The glob is `allow_empty`: a plugin ships sources in only some of the
    extensions, and a package may ship a platform directory with none.
    """
    patterns = []
    excludes = []
    for d in srcs_dirs:
        for ext in extensions:
            patterns.append("{}/**/*.{}".format(d, ext))
        excludes.append("{}/test/**".format(d))
        excludes.append("{}/example/**".format(d))
    quoted = ['        "%s",' % p for p in patterns]
    excl_quoted = ['        "%s",' % e for e in excludes]
    return "glob(\n        [\n{}\n        ],\n        exclude = [\n{}\n        ],\n        allow_empty = True,\n    )".format("\n".join(quoted), "\n".join(excl_quoted))

def _split_glob_block(srcs_dirs, src_exts, hdr_exts):
    """Format separate srcs/hdrs glob expressions for desktop plugins.

    Returns (srcs_glob, hdrs_glob) so the spoke can pass the lists to
    flutter_linux_plugin_library / flutter_windows_plugin_library
    separately — those rules require .h/.hh/.hpp on `hdrs` and the
    compilable extensions on `srcs`.
    """
    return _glob_block(srcs_dirs, src_exts), _glob_block(srcs_dirs, hdr_exts)

_DESKTOP_HDR_EXTS = ("h", "hh", "hpp")
_DESKTOP_C_EXTS = ("cc", "cpp", "c")

def _files_in(ctx, rel_dir):
    """The files directly in `<package>/<rel_dir>`, as package-relative paths.

    Not the files below it: Flutter does not recurse into a listed
    directory, which is what keeps `assets/` from shipping `assets/dev/`.
    A directory that is not there lists nothing.
    """
    directory = ctx.path(rel_dir)
    if not directory.exists:
        return []
    return sorted([
        "{}/{}".format(rel_dir, child.basename)
        for child in directory.readdir()
        if not child.is_dir
    ])

def _file_name_problem(path):
    """Why `path` cannot be the name of a file in a BUILD file, or "".

    Every file a package lists (assets, fonts, shaders, and the files under a
    listed directory) becomes a label in the spoke's generated BUILD file, so a
    name has to be one a label can carry. A quote or a `$` is fine: the name is
    written as a string literal (`repr`), never spliced into the BUILD file's
    text. A colon, a backslash, a control character and a path that leaves the
    package or is not normalised are not.
    """
    if not path:
        return "is empty"
    for c in path.elems():
        if c == ":":
            return "contains a colon, which a Bazel label cannot"
        if c == "\\":
            return "contains a backslash, which a Bazel label cannot"
        if c < " " or c == "\177":
            return "contains a control character"
    for segment in path.split("/"):
        if segment in ("", ".", ".."):
            return "is not a normalised path inside the package (it has an empty, `.` or `..` segment)"
    return ""

def _checked_file_name(package, what, path):
    """Return `path`, or fail naming the package and the file it cannot hold."""
    problem = _file_name_problem(path)
    if problem:
        fail("package {}: the {} {} {}, so rules_flutter cannot put it in the package's BUILD file.".format(
            package,
            what,
            repr(path),
            problem,
        ))
    return path

def _encode_fonts_json(parsed_fonts):
    """Convert flutter_assets_block().fonts to the JSON shape flutter_library expects."""
    fonts_for_json = []
    for entry in parsed_fonts:
        fonts_list = []
        for font in entry.fonts:
            d = {"asset": font.asset}
            if font.weight != None:
                d["weight"] = font.weight
            if font.style != None:
                d["style"] = font.style
            fonts_list.append(d)
        fonts_for_json.append({"family": entry.family, "fonts": fonts_list})
    return json.encode(fonts_for_json) if fonts_for_json else ""

def _font_label(ctx, path):
    """The label of the file of the font a package lists at `path`.

    As in flutter_tools, `packages/<other>/<rest>` that is no file of this
    package is the file `<rest>` of the package `<other>`, which need not list
    it. A file of another package is linked into this repository rather than
    named across repositories: a package's files are private to it, and any of
    them can be named this way.
    """
    parts = path.split("/", 2)
    if parts[0] != "packages" or len(parts) < 3 or ctx.path(path).exists:
        return ":" + path
    other, rest = parts[1], parts[2]
    if other == ctx.attr.package_name:
        return ":" + rest
    index = read_index(ctx, ctx.attr.prefix)
    if other not in index.built:
        fail("package {}: the font file {} names the package {}, which the lock does not build.".format(ctx.attr.package_name, repr(path), other))
    file = sibling_path(ctx, source_repo(other, owner_prefix(index, other)), "pubspec.yaml").dirname.get_child(rest)
    if not file.exists:
        fail("package {}: the font file {} names {} of the package {}, which has no such file.".format(ctx.attr.package_name, repr(path), repr(rest), other))
    link = "_fonts_of_other_packages/{}/{}".format(other, rest)
    ctx.symlink(file, link)
    return ":" + link

def _build_font_files_dict(ctx, parsed_fonts):
    """Build the `font_files` label_keyed_string_dict literal, {label: path, ...}."""
    out = {}
    for entry in parsed_fonts:
        for font in entry.fonts:
            path = _checked_file_name(ctx.attr.package_name, "font file", font.asset)
            out[_font_label(ctx, path)] = path
    return out

def _with_variants(ctx, package, path):
    """`path` if it is a file, and the files of that name in its `<number>x/` siblings.

    The resolution variants of an image are found beside it, in the
    directories next to it named for a scale (see `variant_scale`), as
    flutter_tools finds them. The listed file itself need not exist when a
    variant does; when neither does, the package lists something it does not
    ship, which `flutter build` fails on and so does this.
    """
    slash = path.rfind("/")
    prefix = path[:slash + 1]
    name = path[slash + 1:]
    found = []
    if ctx.path(path).exists:
        found.append(path)
    beside = ctx.path(prefix.rstrip("/") or ".")
    if beside.exists:
        for sibling in beside.readdir():
            if sibling.is_dir and variant_scale(sibling.basename) != None:
                variant = sibling.get_child(name)
                if variant.exists and not variant.is_dir:
                    found.append("{}{}/{}".format(prefix, sibling.basename, name))
    if not found:
        fail("package {}: it lists the asset {}, but neither that file nor a resolution variant of it exists.".format(package, repr(path)))
    return sorted(found)

def _build_pkg_assets(ctx, package, parsed_assets, flavors):
    """Expand the package's `flutter: assets:` entries into files.

    Bazel needs an explicit label per file, so each entry is expanded at
    repo-rule time as flutter_tools expands it. A file entry is the file and
    its resolution variants. A directory entry (a trailing slash) is the files
    directly in it, each with its variants, and nothing from the directories
    below it, which need an entry of their own.

    An entry with `flavors:` ships in builds of one of those flavors (the
    `flavor` of the application), and in no build without a flavor. An entry
    with `platforms:` ships in builds for those platforms only; a file that
    several entries list ships wherever any of them does.

    Args:
        ctx: The repository context.
        package: The package name.
        parsed_assets: The package's parsed `flutter: assets:` entries.
        flavors: The package's `flavor_restrictions`, shared with its shaders.

    Returns:
        struct(files, platforms): `files` is the `pkg_assets` dict (file label
        -> package-relative path); `platforms` maps the path of each file that
        ships on some platforms only to those platforms.
    """
    files = {}
    restrictions = _platform_restrictions()
    for entry in parsed_assets:
        path = entry.path
        listed = _files_in(ctx, path.rstrip("/")) if path.endswith("/") else [path]
        for f in listed:
            main = _checked_file_name(package, "asset file", f)
            for variant in _with_variants(ctx, package, main):
                files[":" + variant] = variant
                restrictions.add(variant, entry.platforms)
                conflict = flavors.add(variant, path, entry.flavors, main = variant == main)
                if conflict:
                    fail(conflict)
    return struct(files = files, platforms = restrictions.platforms())

def _build_additional_licenses(ctx, package, paths):
    """The labels of the files a package lists under `flutter: licenses:`.

    flutter_tools fails the build when one is missing; here the fetch does,
    naming the package and the file, since a label for it cannot be written.

    Returns:
        The package-relative paths, in the order listed, as labels of the
        package's own files.
    """
    labels = []
    for path in paths:
        _checked_file_name(package, "licence file", path)
        file = ctx.path(path)
        if not file.exists or file.is_dir:
            fail("package {}: its `flutter: licenses:` lists {}, which is not a file of the package.".format(package, repr(path)))
        labels.append(":" + path)
    return labels

def _build_pkg_shaders(package, parsed_shaders, flavors):
    """Expand the package's `flutter: shaders:` entries into files.

    The same rules as for assets (see `_build_pkg_assets`): an entry with
    `flavors:` ships in builds of those flavors, one with `platforms:` only in
    builds for those platforms. There are no directories and no resolution
    variants.

    Args:
        package: The package name.
        parsed_shaders: The package's parsed `flutter: shaders:` entries.
        flavors: The package's `flavor_restrictions`, shared with its assets.

    Returns:
        struct(files, platforms): `files` is the `pkg_shaders` dict;
        `platforms` maps the path of each shader that ships on some platforms
        only to those platforms.
    """
    files = {}
    restrictions = _platform_restrictions()
    for entry in parsed_shaders:
        _checked_file_name(package, "shader file", entry.path)
        files[":" + entry.path] = entry.path
        restrictions.add(entry.path, entry.platforms)
        conflict = flavors.add(entry.path, entry.path, entry.flavors)
        if conflict:
            fail(conflict)
    return struct(files = files, platforms = restrictions.platforms())

def _platform_restrictions():
    """The platforms each file of a package ships on, from the entries that list it.

    A file that several entries list ships wherever any of them does, so one
    entry without `platforms:` makes it unrestricted.
    """
    listed = {}
    unrestricted = {}

    def add(path, platforms):
        if platforms:
            listed[path] = listed.get(path, []) + platforms
        else:
            unrestricted[path] = True

    def restricted():
        return {
            path: sorted({p: True for p in names}.keys())
            for path, names in listed.items()
            if path not in unrestricted
        }

    return struct(add = add, platforms = restricted)

def flavor_restrictions(package):
    """The flavors each file of a package ships in, from the entries that list it.

    Assets and shaders share one tracker per package, as flutter_tools keeps
    one map per package: a file that two entries reach with different flavor
    sets is a conflict, whatever flavor is being built, and fails the
    package as it fails `flutter build`.

    Args:
        package: The package name, for the conflict message.

    Returns:
        struct(add, flavors). `add(path, origin, flavors, main = True)` records
        that the entry written `origin` (a directory ends in `/`) lists the
        file `path` for `flavors`. It returns None, or for a main file whose
        flavors differ from an earlier entry's, flutter_tools' conflict
        message. A resolution variant (`main = False`) is recorded without the
        check, as flutter_tools checks the main file only. `flavors()` is the
        flavors of each file that ships in some flavors only.
    """
    seen = {}

    def describe(origin, flavors):
        if not flavors:
            return 'An entry with the path "{}" does not specify any flavors.'.format(origin)
        return 'An entry with the path "{}" specifies the flavor(s): {}.'.format(
            origin,
            ", ".join(['"{}"'.format(f) for f in flavors]),
        )

    def add(path, origin, flavors, main = True):
        flavors = sorted({f: True for f in flavors}.keys())
        if path not in seen:
            seen[path] = (origin, flavors)
            return None
        earlier_origin, earlier_flavors = seen[path]
        if not main or earlier_flavors == flavors:
            return None
        message = 'package {}: Multiple assets entries include the file "{}", but they specify different lists of flavors.\n{}\n{}'.format(
            package,
            path,
            describe(earlier_origin, earlier_flavors),
            describe(origin, flavors),
        )
        if origin.endswith("/") or earlier_origin.endswith("/"):
            message += "\n\nConsider organizing assets with different flavors into different directories."
        return message

    def restricted():
        return {path: flavors for path, (_, flavors) in seen.items() if flavors}

    return struct(add = add, flavors = restricted)

def _format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    keys = sorted(d.keys())
    lines = ["{indent}{k}: {v},".format(indent = indent, k = repr(k), v = repr(d[k])) for k in keys]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def _format_list_dict_literal(d, indent = "        "):
    """Render `{"foo": ["a", "b"]}` as a multi-line BUILD source dict."""
    lines = ["{indent}{k}: {v},".format(indent = indent, k = repr(k), v = repr(d[k])) for k in sorted(d.keys())]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

# `allow_empty`: most packages ship no shader includes.
_SHADER_INCLUDES_GLOB = """    shader_includes = glob(
        ["**/*.glsl", "**/*.frag", "**/*.vert"],
        allow_empty = True,
    ),"""

def _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms = {}, pkg_shader_platforms = {}, pkg_asset_flavors = {}, pkg_shader_flavors = {}, additional_licenses = []):
    """Render the four pub-asset attrs as BUILD source, omitting empty ones."""
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = {},".format(repr(fonts_json_str)))
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_asset_platforms:
        parts.append("    pkg_asset_platforms = {},".format(_format_list_dict_literal(pkg_asset_platforms)))
    if pkg_asset_flavors:
        parts.append("    pkg_asset_flavors = {},".format(_format_list_dict_literal(pkg_asset_flavors)))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))
    if additional_licenses:
        parts.append("    additional_licenses = {},".format(repr(additional_licenses)))
    if pkg_shader_platforms:
        parts.append("    pkg_shader_platforms = {},".format(_format_list_dict_literal(pkg_shader_platforms)))
    if pkg_shader_flavors:
        parts.append("    pkg_shader_flavors = {},".format(_format_list_dict_literal(pkg_shader_flavors)))
    if pkg_shaders:
        # What the shaders may `#include`: a package's GLSL anywhere in it,
        # since an include can reach `../`.
        parts.append(_SHADER_INCLUDES_GLOB)
    return ("\n".join(parts) + "\n") if parts else ""

def _format_code_asset_attrs(code_assets, has_unreplaced_hook):
    """Render the `code_assets` / `has_unreplaced_hook` attrs for a spoke.

    Shared by the `flutter_library` and `flutter_plugin` generators so the two
    emit an identical shape; the `dart_library` branch gets the equivalent from
    rules_dart's own `make_dart_library_build_content`.
    """
    block = ""
    if code_assets:
        lines = ["        {},".format(repr(a)) for a in code_assets]
        block += "    code_assets = [\n{}\n    ],\n".format("\n".join(lines))
    if has_unreplaced_hook:
        block += "    has_unreplaced_hook = {},\n".format(repr(has_unreplaced_hook))
    return block

# The non-Dart remainder of `lib/`, emitted verbatim by both spoke
# generators below — the same partition rules_dart's
# `make_dart_library_build_content` uses, so `srcs + resources = lib/**`
# holds for every spoke whichever generator ran. A published package's
# `lib/` is addressable as `package:<name>/<path>` whatever the extension;
# a spoke that keeps only `*.dart` is a package with pieces missing.
# `resources` is orthogonal to the declared-asset attrs (`pkg_assets` /
# `pkg_shaders` / `font_files`): those name what is transformed and bundled
# into flutter_assets, while `resources` names membership in the staged
# package tree. A shader under `lib/` is legitimately both.
#
# `allow_empty`: most packages ship nothing but Dart under `lib/`.
_RESOURCES_GLOB_BLOCK = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
"""

def _format_version_attr(version):
    """The `version` attr line for a spoke, or nothing when it is unknown.

    Omitted rather than written empty, matching
    `make_dart_library_build_content`. The attribute's only use is agreement
    checking between two records for one package name, and an unstated version
    never conflicts — so a spoke with nothing to say says nothing.

    Args:
        version: The resolved package version, or "".

    Returns:
        A BUILD attribute line, or "".
    """
    return '    version = "{}",\n'.format(version) if version else ""

def _format_license_file_attr(license_file):
    """Format the `license_file` attribute line of a member, or nothing.

    Args:
        license_file: The package-relative name `find_pub_license_file` found, or "".

    Returns:
        A BUILD attribute line, or "".
    """
    return '    license_file = "{}",\n'.format(license_file) if license_file else ""

def make_dart_member_build_content(name, language_version, code_assets, has_unreplaced_hook, version = "", license_file = ""):
    """Generate BUILD content for the source repository of a pure-Dart pub package.

    A package with nothing of Flutter's in its pubspec is rules_dart's own
    `pub_package_member`, as a package fetched by `pub.from_lock()` is, so
    it reaches consumers as it does under `pub.pub()`: no `FlutterInfo`.

    Args:
        name: Target name (also the `package_name`).
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        version: The resolved package version, or "".
        license_file: The package's `NOTICES` or `LICENSE` (`find_pub_license_file`), or "".

    Returns:
        BUILD.bazel content as a string.
    """
    return """\
load("@rules_dart//dart/pub:pub_library.bzl", "pub_package_member")

pub_package_member(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}    package_name = "{name}",
    language_version = "{language_version}",
{version}{license}{asset_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        resources = _RESOURCES_GLOB_BLOCK,
        language_version = language_version,
        version = _format_version_attr(version),
        license = _format_license_file_attr(license_file),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
    )

def make_flutter_member_build_content(
        name,
        language_version,
        code_assets,
        has_unreplaced_hook,
        plugin_platforms_json = "",
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        version = "",
        linux_link = None,
        windows_link = None,
        pkg_asset_platforms = {},
        pkg_shader_platforms = {},
        additional_licenses = [],
        pkg_asset_flavors = {},
        pkg_shader_flavors = {},
        has_android_lib = False,
        license_file = ""):
    """Generate BUILD content for the source repository of a Flutter pub package.

    Emits the package's `flutter_pub_member`, a plugin when
    `plugin_platforms_json` is given and otherwise a package that only
    bundles fonts, assets and shaders (`cupertino_icons`), plus optional
    per-platform `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    Android Kotlin/Java sources are exposed via a sibling `android/`
    sub-package (see `make_android_subpackage_build_content`), which the
    member lists under its `exports`, in a `select()` on
    `@platforms//os:android`. Only an Android build analyses that label, so
    only an Android build loads the sub-package: a macOS, web or desktop
    workspace never pays the `@rules_android` / `@rules_kotlin` cost, and an
    Android app links the libraries of the plugins it depends on, no others.

    The member has no dependencies: those belong to the library of the
    package's dependency cycle (`flutter_pub_library`), which the package's
    library repository writes once it knows the cycle.

    Args:
        name: Target name (also the `package_name`).
        license_file: The package's `NOTICES` or `LICENSE` (`find_pub_license_file`), or "".
        has_android_lib: Whether the package has an `android/` sub-package
            that defines `:lib`, which the member lists under `exports`,
            selected on Android.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict;
            empty for a package that is not a plugin.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        apple_macos_privacy_manifests: `PrivacyInfo.xcprivacy` paths (macOS).
        apple_ios_privacy_manifests: `PrivacyInfo.xcprivacy` paths (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_asset_platforms: Dict of package-relative asset path -> the platforms
            it ships on, for the assets a `platforms:` entry restricts.
        pkg_asset_flavors: Dict of package-relative asset path -> the flavors
            it ships in, for the assets a `flavors:` entry restricts.
        pkg_shaders: Dict of shader file label -> package-relative path.
        pkg_shader_platforms: Dict of package-relative shader path -> the
            platforms it ships on, for the shaders a `platforms:` entry restricts.
        pkg_shader_flavors: Dict of package-relative shader path -> the flavors
            it ships in, for the shaders a `flavors:` entry restricts.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.
        linux_link: The result of `parse_cmake_link_libraries` for the plugin's
            `linux/CMakeLists.txt`, or None.
        windows_link: Same, for `windows/CMakeLists.txt`.
        additional_licenses: Labels of the files `flutter: licenses:` lists.

    Returns:
        BUILD.bazel content as a string.
    """
    extra_loads = []
    extra_targets = []
    apple_libs_arg = ""
    linux_libs_arg = ""
    windows_libs_arg = ""

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')

    # NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    # spoke BUILD. Instead, they're exposed via a sibling `android/`
    # sub-package (see make_android_subpackage_build_content) which loads
    # @rules_android + @rules_kotlin lazily. The member names that package's
    # `:lib` under its `exports`, selected on Android only, so a mac-only /
    # web-only workspace never triggers the parse and doesn't pay the
    # @rules_android / @rules_kotlin cost, and an Android app links the
    # libraries of the plugins it depends on.

    if apple_macos_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_macos",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "macos",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_macos_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_macos_include_dirs),
        ))

    if apple_ios_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_ios",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "ios",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_ios_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_ios_include_dirs),
        ))

    if linux_src_dir:
        linux_srcs, linux_hdrs = _split_glob_block([linux_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_linux_plugin_library(
    name = "{name}_linux",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["linux/include"],
{link_attrs}    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = linux_srcs,
            hdrs = linux_hdrs,
            link_attrs = _format_link_attrs(linux_link) if linux_link else "",
        ))

    if windows_src_dir:
        win_srcs, win_hdrs = _split_glob_block([windows_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_windows_plugin_library(
    name = "{name}_windows",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["windows/include"],
{link_attrs}    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = win_srcs,
            hdrs = win_hdrs,
            link_attrs = _format_link_attrs(windows_link) if windows_link else "",
        ))

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
        ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
        apple_libs_arg = """    apple_libs = select({{
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
            macos_branch = macos_branch,
            ios_branch = ios_branch,
        )

    if linux_src_dir:
        linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = name)

    if windows_src_dir:
        windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = name)

    # Android sources travel through a sibling `android/` sub-package, whose
    # `:lib` the member lists under its `exports` on Android only.
    android_lib_arg = ""
    if has_android_lib:
        android_lib_arg = """    exports = select({
        "@platforms//os:android": ["//android:lib"],
        "//conditions:default": [],
    }),
"""

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/. Split per-platform
    # via select() so the macOS bundle never picks up iOS-only manifests
    # (and vice versa) — different platforms can declare different privacy
    # uses, and Apple's submission validator aggregates whatever it finds in
    # the per-platform bundle.
    apple_privacy_files_arg = ""
    if apple_macos_privacy_manifests or apple_ios_privacy_manifests:
        macos_lines = "\n".join(["            {},".format(repr(p)) for p in apple_macos_privacy_manifests])
        ios_lines = "\n".join(["            {},".format(repr(p)) for p in apple_ios_privacy_manifests])
        apple_privacy_files_arg = """    apple_privacy_files = select({{
        "@platforms//os:macos": [
{macos_lines}
        ],
        "@platforms//os:ios": [
{ios_lines}
        ],
        "//conditions:default": [],
    }}),
""".format(
            macos_lines = macos_lines,
            ios_lines = ios_lines,
        )

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms, pkg_shader_platforms, additional_licenses = additional_licenses, pkg_asset_flavors = pkg_asset_flavors, pkg_shader_flavors = pkg_shader_flavors)

    # The `lib/` glob is `allow_empty`: a pub package can be only assets or native
    # code, with no Dart.
    return """\
load("@rules_flutter//flutter/private:flutter_pub_library.bzl", "flutter_pub_member")
{extra_loads}
flutter_pub_member(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}    package_name = "{name}",
{plugin_platforms_json_attr}    language_version = "{language_version}",
{version}{license}{android_lib_arg}{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}{apple_privacy_files_arg}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        version = _format_version_attr(version),
        license = _format_license_file_attr(license_file),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        resources = _RESOURCES_GLOB_BLOCK,
        language_version = language_version,
        plugin_platforms_json_attr = "    plugin_platforms_json = {},\n".format(repr(plugin_platforms_json)) if plugin_platforms_json else "",
        extra_loads = "\n".join(extra_loads),
        extra_targets = "\n".join(extra_targets),
        android_lib_arg = android_lib_arg,
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

def make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        maven_deps = [],
        android_manifest = "",
        consumer_proguard_specs = [],
        has_resources = False):
    """Generate `android/BUILD.bazel` content for a Flutter plugin spoke.

    Emits a `kt_android_library(name = "lib", ...)`, which the spoke's member
    lists under `exports` on Android. The spoke of a package with no Android
    sources or resources has no such package.

    Loaded lazily — Bazel only parses this file when an Android build
    analyses the member's `exports`. Non-Android workspaces never trigger
    it and don't pay the `@rules_android` / `@rules_kotlin` cost.

    The `_engine` target gives the plugin's Kotlin/Java source access to
    the FlutterPlugin SPI on the compile classpath. It is `neverlink`, as
    Gradle gives a plugin the embedding with `compileOnly`: the app
    packages its own engine, of each ABI of
    `--@rules_android//flags:android_platforms`. The plugin's is the
    arm64 one whatever the app's ABI, since Java bytecode is
    ABI-independent, and packaged it would put an arm64 engine in an x64
    APK. The engine also exports the embedding's
    androidx dependencies (see `_ANDROIDX_EMBEDDING_DEPS` in
    `flutter/android.bzl`), so a plugin whose `build.gradle` declares no
    dependencies still compiles against `NotificationCompat` & co. —
    exactly the compile classpath Gradle gives it via the
    `io.flutter:flutter_embedding_*` POM.

    BuildConfig.java is generated from the plugin's `java_package`. Many
    Flutter plugins reference `BuildConfig.DEBUG`, which Gradle synthesizes
    automatically; rules_android does not. `android_build_config` emits it,
    with `DEBUG` and `BUILD_TYPE` as Gradle's would be in the build's mode
    (debug: true and `debug`, profile: true and `profile`, release: false
    and `release`).

    Args:
        android_src_dir: Source dir under the package root (e.g.
            `android/src/main`) when the spoke has Android sources, or
            empty when it doesn't.
        java_package: The plugin's Android namespace — resolved the way
            AGP resolves it (`android.namespace` in `build.gradle(.kts)`,
            else the manifest's `package` attribute), falling back to
            `flutter.plugin.platforms.android.package` from the spoke's
            pubspec.yaml. Used as `custom_package` on the
            `kt_android_library` so the generated `R` and `BuildConfig`
            classes land in the package the plugin's sources expect.
        maven_deps: The plugin's Maven dependencies as declared in its
            `build.gradle*`: dicts with `kind` (`"deps"`, `"compile_only"`,
            `"runtime"`), `coordinate` (`group:artifact`), `version` (string
            or None) and `line`. When non-empty the generated library depends
            on the artifacts `@rules_android_maven` resolved. One it lacks is
            left out, so that the application's `flutter_android_plugin_libs`
            reports it, by name, with the rest the app needs, rather than
            Bazel failing on a label that does not exist.
        android_manifest: Path to the plugin's
            `android/src/main/AndroidManifest.xml` if it ships one, or
            empty. When set, the generated `kt_android_library` declares
            `manifest = ...` so `android_binary`'s manifest merger
            (`ManifestMerger2`) picks the plugin's `<activity>` /
            `<service>` / `<uses-permission>` / etc. entries up
            transitively — same shape AGP uses inside `flutter build apk`.
        consumer_proguard_specs: Paths (relative to the spoke's
            `android/` sub-package) to ProGuard / R8 keep-rule files
            the plugin declared via `consumerProguardFiles` in its
            `build.gradle`. Threaded through as `proguard_specs = [...]`
            on the generated `kt_android_library`; rules_android
            propagates them transitively to the consuming
            `android_binary`'s R8 invocation, mirroring AGP's
            `consumerProguardFiles` flow.
        has_resources: True when the plugin ships resources at
            `android/src/main/res/`. Compiled via `resource_files` so the
            plugin's `R` class is generated against `java_package` and
            the resources merge into the consuming APK.

    Returns:
        Generated BUILD content as a string.
    """
    if has_resources and not java_package:
        fail(
            "Plugin ships Android resources (android/src/main/res/) but " +
            "declares no namespace — checked android.namespace in " +
            "build.gradle(.kts), the AndroidManifest.xml package " +
            "attribute, and flutter.plugin.platforms.android.package in " +
            "pubspec.yaml. Without a namespace the R class cannot be " +
            "generated, so the resources would not compile.",
        )

    if android_src_dir:
        # Source dir is relative to the package root; the sub-package
        # itself lives at `android/`, so strip that prefix.
        if android_src_dir.startswith("android/"):
            sub_src = android_src_dir[len("android/"):]
        else:
            sub_src = android_src_dir

        # `allow_empty`: a plugin's Android directory can hold resources and
        # no code.
        srcs_attr = "glob([{kt}, {java}], allow_empty = True)".format(
            kt = repr(sub_src + "/**/*.kt"),
            java = repr(sub_src + "/**/*.java"),
        )
    else:
        srcs_attr = "[]"

    custom_package_arg = ""
    if java_package:
        custom_package_arg = "    custom_package = %s,\n" % repr(java_package)

    # `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick
    # up the plugin's `<activity>` / `<service>` / `<uses-permission>`
    # / etc. entries transitively — same shape AGP uses inside
    # `flutter build apk`. `exports_manifest = 1` is required because
    # rules_android's `android_library` defaults to `no` (AGP defaults
    # to yes); without it, the library's manifest is parsed for itself
    # but never contributed to the binary's merger inputs. Path is
    # relative to the `android/` sub-package, so we strip the
    # `android/` prefix the same way `sub_src` does.
    #
    # rules_android additionally requires *some* manifest whenever
    # `resource_files` is set. AGP treats a missing library manifest as
    # an empty one, so for a res-bearing plugin that ships no manifest
    # we synthesize the equivalent (namespaced, contributing nothing to
    # the merger — hence no `exports_manifest`).
    manifest_arg = ""
    synthesized_manifest = ""
    write_file_load = ""
    if android_manifest:
        sub_manifest = android_manifest
        if sub_manifest.startswith("android/"):
            sub_manifest = sub_manifest[len("android/"):]
        manifest_arg = "    manifest = %s,\n    exports_manifest = 1,\n" % repr(sub_manifest)
    elif has_resources:
        manifest_arg = '    manifest = ":_manifest",\n'
        write_file_load = 'load("@bazel_skylib//rules:write_file.bzl", "write_file")\n'
        synthesized_manifest = """
# Minimal manifest for resource processing. AGP treats a missing library
# manifest as an empty one; rules_android requires an explicit file when
# resource_files is set.
write_file(
    name = "_manifest",
    out = "_manifest/AndroidManifest.xml",
    content = [
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android"',
        '    package="{pkg}">',
        "</manifest>",
        "",
    ],
    newline = "unix",
)
""".format(pkg = java_package)

    # Resources are compiled into the library so the plugin's `R` class
    # resolves at compile time and the resources merge into the consuming
    # APK. `allow_empty = False` — resource detection already saw files
    # here, so an empty glob means the layout assumption broke.
    resource_files_arg = ""
    if has_resources:
        resource_files_arg = '    resource_files = glob(["src/main/res/**"], allow_empty = False),\n'

    # `proguard_specs = [...]` lets `android_binary`'s R8 step pick up
    # the plugin's keep rules transitively — same shape AGP uses for
    # `consumerProguardFiles`. The paths are relative to the `android/`
    # sub-package, which is where the spoke lives in our layout.
    proguard_specs_arg = ""
    if consumer_proguard_specs:
        spec_lines = ", ".join([repr(path) for path in consumer_proguard_specs])
        proguard_specs_arg = "    proguard_specs = [%s],\n" % spec_lines

    # Base deps every plugin spoke gets: the engine (which carries the
    # FlutterPlugin SPI plus the embedding's androidx compile classpath
    # via its exports) and the BuildConfig stub. The plugin's own Maven
    # artifacts come from `@rules_android_maven`, checked by the application
    # that links this library (see `flutter_android_plugin_libs`).
    deps_expr = '[":_engine", ":_build_config"]'
    maven_loads = ""
    maven_call = ""
    compile_only_target = ""
    runtime_deps_arg = ""
    if maven_deps:
        maven_loads = (
            'load("@flutter_pub_android_maven//:resolved.bzl", "RESOLVED")\n' +
            'load("@rules_android//android:rules.bzl", "android_library")\n' +
            'load("@rules_flutter//flutter/private:android_plugin_maven.bzl", "maven_labels")\n'
        )
        maven_call = """
# The artifacts this plugin's Gradle build declares that @rules_android_maven
# has. An application that links the plugin fails, naming every one it lacks
# or has too low, before this library is built (`flutter_android_plugin_libs`).
_maven = maven_labels({declared}, RESOLVED)
""".format(declared = repr(maven_deps))
        deps_expr += " + _maven.deps"
        if [d for d in maven_deps if d["kind"] == "compile_only"]:
            deps_expr += ' + [":_compile_only"]'
            compile_only_target = """
# The plugin's compileOnly / provided dependencies: on its compile classpath,
# not in the APK.
android_library(
    name = "_compile_only",
    neverlink = True,
    exports = _maven.compile_only,
    visibility = ["//visibility:private"],
)
"""
        if [d for d in maven_deps if d["kind"] == "runtime"]:
            runtime_deps_arg = "    runtime_deps = _maven.runtime_deps,\n"

    # BuildConfig.java stub — Gradle generates this implicitly per
    # plugin's namespace. rules_android does not, so we hand-emit one.
    bc_package = java_package if java_package else "_unknown"

    return """\
{maven_loads}{write_file_load}load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_flutter//flutter/private:android_build_config.bzl", "android_build_config")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
{maven_call}
# Private engine target — gives the plugin's Kotlin/Java the FlutterPlugin
# SPI plus the embedding's androidx dependencies (via the engine's
# exports) on the compile classpath. Always arm64; Java bytecode is
# ABI-independent. neverlink, so the APK carries only the app's engine, of
# each ABI of --@rules_android//flags:android_platforms.
flutter_android_engine(
    name = "_engine",
    neverlink = True,
    visibility = ["//visibility:private"],
)

# BuildConfig for the plugin's namespace, which Gradle generates and
# rules_android does not. DEBUG and BUILD_TYPE follow the build mode.
android_build_config(
    name = "_build_config",
    package = "{bc_package}",
)
{synthesized_manifest}{compile_only_target}
kt_android_library(
    name = "lib",
    srcs = {srcs},
{custom_package}{manifest}{resource_files}{proguard_specs}{runtime_deps}    visibility = ["//visibility:public"],
    deps = {deps},
)
""".format(
        srcs = srcs_attr,
        custom_package = custom_package_arg,
        manifest = manifest_arg,
        resource_files = resource_files_arg,
        proguard_specs = proguard_specs_arg,
        deps = deps_expr,
        maven_loads = maven_loads,
        maven_call = maven_call,
        compile_only_target = compile_only_target,
        runtime_deps = runtime_deps_arg,
        bc_package = bc_package,
        synthesized_manifest = synthesized_manifest,
        write_file_load = write_file_load,
    )

# The hook entrypoints upstream Dart defines (`package:hooks` — `build` and
# `link`). A package shipping one produces native libraries by running Dart at
# build time, which Bazel cannot do hermetically; something must stand in for it.
_DART_BUILD_HOOKS = ["hook/build.dart", "hook/link.dart"]

def _detect_unreplaced_hook(ctx):
    """Return the path of a build hook nothing replaces, or "".

    Recording rather than failing here is deliberate, and matches rules_dart:
    the whole lock is materialised, including packages nothing depends on, so
    failing at repo generation would break builds over packages never reached.
    The application that actually depends on one fails instead.
    """
    if ctx.attr.code_assets or ctx.attr.ignore_hook:
        return ""
    for candidate in _DART_BUILD_HOOKS:
        if ctx.path(candidate).exists:
            return candidate
    return ""

_LANGUAGE_VERSION_PLACEHOLDER = "{LANGUAGE_VERSION}"
_DEPS_PLACEHOLDER = "{DEPS}"

# Where an overlay states its package's licence: the `license_file` attribute
# line the generated spokes carry, or nothing for a package with none.
_LICENSE_PLACEHOLDER = "{LICENSE}"

# The prefixes a repository label of another package takes in an overlay
# template. Finding one means the template names a sibling package by hand.
_HUB_DEP_PREFIXES = ["@flutter_pub__", "@flutter_pub_lib__"]

# The placeholder that named the hub, when each hub had repositories of its own.
# There is one repository per package for the whole build now.
_REMOVED_HUB_PLACEHOLDER = "{HUB_NAME}"

def removed_hub_placeholder_error(tpl):
    """The error for an overlay template that still writes `{HUB_NAME}`.

    Args:
        tpl: The template's path, for the message.

    Returns:
        The message.
    """
    return (
        "overlay template {tpl} writes `{HUB_NAME}`, which is gone: " +
        "packages are one repository per build, not one per hub. " +
        "Name dependencies with `{DEPS}`."
    ).replace("{tpl}", tpl)

def has_removed_hub_placeholder(content):
    """Whether an overlay template writes the removed `{HUB_NAME}` placeholder.

    Args:
        content: Raw template text.

    Returns:
        True when it does.
    """
    return _REMOVED_HUB_PLACEHOLDER in content

def find_hardcoded_language_version(content):
    """Return the literal language version an overlay spells out, or `""`.

    A package's `environment.sdk` is the only place its language version is
    declared; the spoke derives from it and substitutes
    `{LANGUAGE_VERSION}`. A template that writes the version out instead is a
    second declaration of the same fact, and the one that wins — the overlay
    replaces generated content wholesale. The two then drift silently,
    because the overlay ladder is version-ranged: `ext/objective_c/9/` serves
    every 9.x, so a release that raises the SDK floor keeps the old literal.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending literal (e.g. `"3.3"`), or `""` when the template
        either uses the placeholder or declares no language version.
    """
    marker = "language_version"
    idx = content.find(marker)
    for _ in range(len(content)):
        if idx == -1:
            return ""
        rest = content[idx + len(marker):].lstrip(" ")
        if rest.startswith("="):
            value = rest[1:].lstrip(" ")
            if value.startswith('"'):
                end = value.find('"', 1)
                if end > 0:
                    literal = value[1:end]
                    if literal != _LANGUAGE_VERSION_PLACEHOLDER:
                        return literal
        idx = content.find(marker, idx + len(marker))
    return ""

def find_hardcoded_hub_dep(content):
    """Return the first hand-written sibling-spoke label an overlay names, or `""`.

    A package's dependencies are declared once, by its own pubspec, and the
    spoke derives the Bazel labels from it — intersected with the lock, so a
    generated spoke can never name a repo the hub did not create. An overlay
    that spells the list out instead declares the same fact twice, and this
    copy wins, because an overlay replaces generated content wholesale.

    The two then drift on the package's next release, and the drift is not
    a stale-but-working list: `objective_c` 9.5.0 dropped `native_toolchain_c`
    from `dependencies` (its build hook stopped using it), so the lock stopped
    carrying that package, while `ext/objective_c/9/` — one directory for the
    whole major — kept asking for `@<hub>__native_toolchain_c`. The build died
    on an unknown repo naming neither `objective_c` nor the overlay.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending label (e.g. `"@flutter_pub__ffi//:ffi"`), or `""`.
    """
    idx = -1
    for prefix in _HUB_DEP_PREFIXES:
        found = content.find(prefix)
        if found != -1 and (idx == -1 or found < idx):
            idx = found
    if idx == -1:
        return ""
    end = content.find('"', idx)
    return content[idx:end] if end > 0 else content[idx:]

def render_overlay_deps(dep_labels):
    """Render `dep_labels` as the body of an overlay's `deps = [...]`.

    Emits one quoted, comma-terminated label per line at the eight-space
    indent a template's `deps = [` block sits at, so the substituted BUILD
    file comes out buildifier-clean.

    Args:
        dep_labels: Fully-qualified labels, in the order they should appear.

    Returns:
        The list body, without the enclosing brackets.
    """
    return "\n        ".join(['"%s",' % label for label in dep_labels])

def apply_overlay_substitutions(content, package_name, version, language_version, deps, license_file = ""):
    """Fill an overlay template's placeholders.

    Args:
        content: Raw template text.
        package_name: Value for `{PKG}`.
        version: Value for `{VERSION}`.
        language_version: Value for `{LANGUAGE_VERSION}`, derived from the
            package's own pubspec.
        deps: Rendered list body for `{DEPS}` (see `render_overlay_deps`),
            derived from the same pubspec-and-lock intersection a generated
            spoke uses.
        license_file: The package's `NOTICES` or `LICENSE` (`find_pub_license_file`)
            for `{LICENSE}`, which becomes its `license_file` line, or nothing.

    Returns:
        The substituted content.
    """
    if license_file:
        content = content.replace(_LICENSE_PLACEHOLDER, 'license_file = "{}",'.format(license_file))
    else:
        content = content.replace("    " + _LICENSE_PLACEHOLDER + "\n", "").replace(_LICENSE_PLACEHOLDER, "")
    return content.replace(
        "{PKG}",
        package_name,
    ).replace(
        "{VERSION}",
        version,
    ).replace(
        _LANGUAGE_VERSION_PLACEHOLDER,
        language_version,
    ).replace(
        _DEPS_PLACEHOLDER,
        deps,
    )

def _resolve_overlay_template(ctx, overlay_root_label, package_name, version, language_version, dep_labels, relpath, guard_hub_deps = False, license_file = ""):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with
    `{PKG}`, `{VERSION}`, `{LANGUAGE_VERSION}` and `{DEPS}` substitutions
    applied) on first match. Returns empty string when no template is found.

    `dep_labels` is a function of no arguments, giving the labels of the
    libraries the package's own pubspec resolves to,
    which `{DEPS}` expands into. `guard_hub_deps` rejects a template that
    hand-writes those labels instead — see `find_hardcoded_hub_dep`. Only the
    top-level BUILD sets it: `{DEPS}` is a Dart dependency list, so it is not
    the right substitute for a sibling label in an `android/` sub-package. It
    also requires `{LICENSE}`, the package's licence, which a template that
    leaves it out would drop from every program's `NOTICES`.

    Currently called for two relpaths:

    * `BUILD.bazel.tpl` — the spoke's top-level BUILD that fully
      replaces the auto-generated content.
    * `android/BUILD.bazel.tpl` — the Android sub-package BUILD,
      replacing the empty-stub `kt_android_library(srcs=[])` that
      otherwise fires when a top-level overlay short-circuits the
      regular auto-gen path. Plugins whose Android side needs real
      sources, or Maven deps the Gradle script declares in a form
      rules_flutter cannot read, ship this alongside the top-level
      overlay.
    """
    root = ctx.path(overlay_root_label).dirname
    pkg_dir = root.get_child(package_name)

    # Every path looked for is watched, found or not: an overlay written
    # later, which is when its author finds out they need one, or one that is
    # more specific than the one in use, must make the next build fetch this
    # repository again. Reading a template watches that template only.
    ctx.watch(pkg_dir)
    if not pkg_dir.exists:
        return ""

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        tpl = pkg_dir.get_child(candidate) if candidate else pkg_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
        ctx.watch(tpl)
        if tpl.exists:
            content = ctx.read(tpl)
            if has_removed_hub_placeholder(content):
                fail(removed_hub_placeholder_error(str(tpl)))
            hardcoded_dep = find_hardcoded_hub_dep(content) if guard_hub_deps else ""
            if hardcoded_dep:
                fail((
                    "overlay template {tpl} hand-writes the dependency " +
                    "`{dep}`.\n" +
                    "A package's dependencies are declared once, by its own " +
                    "pubspec; the spoke derives the labels from it — " +
                    "intersected with the lock, so it can never name a repo " +
                    "the hub did not create. Listing them here declares the " +
                    "same fact twice, and this copy wins, because an overlay " +
                    "replaces generated content wholesale. Because the " +
                    "overlay ladder is version-ranged, a release that changes " +
                    "the package's dependencies then fails on an unknown " +
                    "repo that names neither the package nor this file.\n" +
                    "Write `deps = [\n        {placeholder}\n    ],` instead."
                ).format(
                    tpl = str(tpl),
                    dep = hardcoded_dep,
                    placeholder = _DEPS_PLACEHOLDER,
                ))
            if guard_hub_deps and _LICENSE_PLACEHOLDER not in content:
                fail((
                    "overlay template {tpl} does not write {placeholder}.\n" +
                    "A package's licence is a fact of its files, which the spoke " +
                    "finds; an overlay replaces generated content wholesale, so " +
                    "without the placeholder the package's licence is missing " +
                    "from the `NOTICES` of every program that uses it.\n" +
                    "Write {placeholder} on its own line among the target's attributes."
                ).format(tpl = str(tpl), placeholder = _LICENSE_PLACEHOLDER))
            hardcoded = find_hardcoded_language_version(content)
            if hardcoded:
                fail((
                    "overlay template {tpl} sets language_version = \"{value}\".\n" +
                    "A package's language version is declared once, by its own " +
                    "pubspec `environment.sdk`; the spoke derives it and fills in " +
                    "{placeholder}. Spelling it out here declares the same fact " +
                    "twice, and this copy wins — an overlay replaces generated " +
                    "content wholesale. Because the overlay ladder is " +
                    "version-ranged, the two then drift without a build error.\n" +
                    "Write `language_version = \"{placeholder}\"` instead."
                ).format(
                    tpl = str(tpl),
                    value = hardcoded,
                    placeholder = _LANGUAGE_VERSION_PLACEHOLDER,
                ))
            return apply_overlay_substitutions(
                content = content,
                package_name = package_name,
                version = version,
                language_version = language_version,
                deps = render_overlay_deps(dep_labels()),
                license_file = license_file,
            )
    return ""

def _resolve_overlay(ctx, overlay_root_label, package_name, version, language_version, dep_labels, license_file):
    """Resolve the top-level BUILD.bazel.tpl overlay.

    Equivalent to `_resolve_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the most
    common call shape; consumers wanting the Android sub-package
    template call `_resolve_overlay_template` directly.
    """
    return _resolve_overlay_template(
        ctx,
        overlay_root_label,
        package_name,
        version,
        language_version,
        dep_labels,
        "BUILD.bazel.tpl",
        guard_hub_deps = True,
        license_file = license_file,
    )

# Where the Flutter source's `packages/` is extracted before the one package
# wanted is moved to the repository root.
_FLUTTER_PACKAGES_STAGING = "_flutter_packages"

def fetch_flutter_source_package(ctx, package_name, flutter_version, sha256):
    """Extracts `packages/<package_name>` of the pinned Flutter source at the repository root.

    The tarball is the one every consumer of the framework source fetches,
    pinned to the same digest, so Bazel's repository cache serves it to all
    of them from one download. Extracting it with `stripPrefix` straight to
    the package would fail, for a name the release lacks, with a message about
    archive prefixes that names neither the package nor the lock. So
    `packages/` is extracted into a staging directory, the package's
    pubspec is looked for there, and the package's files are moved up.

    Args:
        ctx: The `repository_ctx`.
        package_name: The package under `packages/` of the Flutter source.
        flutter_version: The Flutter version whose source tarball to fetch.
        sha256: The recorded digest of that tarball.
    """
    ctx.download_and_extract(
        url = flutter_source_tarball_url(flutter_version),
        sha256 = pinned(flutter_version + ".tar.gz", sha256),
        output = _FLUTTER_PACKAGES_STAGING,
        stripPrefix = "flutter-{}/packages".format(flutter_version),
    )
    package_dir = ctx.path(_FLUTTER_PACKAGES_STAGING).get_child(package_name)
    if not package_dir.get_child("pubspec.yaml").exists:
        fail((
            "pubspec.lock lists `{name}` from the Flutter SDK, but Flutter {version}'s " +
            "source has no packages/{name}; re-resolve the lock with the pinned " +
            "toolchain (`bazel run @rules_flutter//flutter:pub -- get`)."
        ).format(name = package_name, version = flutter_version))
    for child in package_dir.readdir():
        ctx.rename(child, ctx.path(child.basename))
    ctx.delete(ctx.path(_FLUTTER_PACKAGES_STAGING))

def _flutter_pub_package_impl(ctx):
    if ctx.attr.framework_json:
        unset = unset_message(ctx)
        if unset:
            write_unset_stub(ctx, [ctx.attr.package_name], unset, member = True)
            return ctx.repo_metadata(reproducible = True)
        link_framework_package(ctx, ctx.attr.package_name)
    elif ctx.attr.flutter_source_version:
        fetch_flutter_source_package(
            ctx,
            package_name = ctx.attr.package_name,
            flutter_version = ctx.attr.flutter_source_version,
            sha256 = ctx.attr.sha256,
        )
    elif ctx.attr.git_url:
        # The lock's commit, laid out as pub lays it out, whichever rule asks.
        fetch_pub_git(
            ctx,
            package_name = ctx.attr.package_name,
            version = ctx.attr.version,
            url = ctx.attr.git_url,
            resolved_ref = ctx.attr.resolved_ref,
            path = ctx.attr.git_path,
            lock = ctx.attr.lock,
        )
    else:
        # Downloads, verifies and extracts the archive the way every pub-backed
        # repository does, so a package is laid out the same whichever rule asks.
        fetch_pub_archive(
            ctx,
            package_name = ctx.attr.package_name,
            version = ctx.attr.version,
            sha256 = ctx.attr.sha256,
            base_url = ctx.attr.base_url,
        )

    # Pub's own reading of the pubspec: a package pub would refuse (malformed
    # YAML, a `name` that is not this package's, a dependency or constraint of
    # the wrong type) fails the fetch, naming the package.
    pubspec = read_pubspec(ctx, ctx.attr.package_name, ctx.attr.version)
    if ctx.attr.framework_json:
        # What a Flutter SDK package of a framework other than the release
        # needs of the hosted packages must be what the locks hold. (A
        # release's are not held to it here: its pins are checked when the
        # module is read.)
        check_dependency_constraints(read_index(ctx, ctx.attr.prefix), ctx.attr.sdk, ctx.attr.package_name, pubspec.fields)
    pubspec_dependencies = pubspec.dependencies
    language_version = pubspec.language_version
    plugin_block = flutter_plugin_block(pubspec.fields)
    manifest_errors = flutter_manifest_errors(pubspec.fields)
    if manifest_errors:
        fail((
            "package {}: its pubspec.yaml has `flutter:` fonts, assets or shaders that `flutter build` refuses:\n  {}"
        ).format(ctx.attr.package_name, "\n  ".join(manifest_errors)))
    asset_block = flutter_assets_block(pubspec.fields)
    license_file = find_pub_license_file(ctx)
    additional_licenses = _build_additional_licenses(ctx, ctx.attr.package_name, flutter_licenses_block(pubspec.fields))
    for asset in asset_block.assets:
        if asset.transformers:
            fail((
                "package {}: its asset {} lists `transformers`, which rules_flutter does not run. " +
                "Bundling the file as it is would ship it untransformed under the transformed file's name."
            ).format(ctx.attr.package_name, repr(asset.path)))

    # The names the pubspec depends on, for the libraries of the packages that
    # reach this one. Which of them the lock lists, and what that makes of
    # this package's dependency cycle, is for its library repository to say.
    write_pubspec_dependencies(ctx, pubspec_dependencies)

    # If the pubspec declares `uses-material-design: true`, the package's
    # library depends on @rules_flutter//flutter:material_icons so the bundled
    # font travels through the deps graph automatically — same channel
    # any other pub package's font flows through. Cross-package mismatch
    # (app says false, pub dep says true) becomes structurally impossible.
    # The library repository reads it from `MEMBER_FILE`.
    uses_material_icons = asset_block.uses_material_design

    # An overlay's own dependencies are the labels of the libraries of the
    # packages the pubspec names that the lock lists. Worked out only for a
    # package an overlay builds: the lock's index is read for no other.
    def dep_labels():
        index = read_index(ctx, ctx.attr.prefix)
        labels = [
            library_label(index, dep)
            for dep in sorted(pubspec_dependencies)
            if dep in index.built or dep in index.other
        ]
        return labels + (["@rules_flutter//flutter:material_icons"] if uses_material_icons else [])

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    fonts_json_str = _encode_fonts_json(asset_block.fonts)
    font_files = _build_font_files_dict(ctx, asset_block.fonts)
    flavors = flavor_restrictions(ctx.attr.package_name)
    pkg_assets = _build_pkg_assets(ctx, ctx.attr.package_name, asset_block.assets, flavors)
    pkg_shaders = _build_pkg_shaders(ctx.attr.package_name, asset_block.shaders, flavors)
    flavored = flavors.flavors()
    pkg_asset_flavors = {p: f for p, f in flavored.items() if ":" + p in pkg_assets.files}
    pkg_shader_flavors = {p: f for p, f in flavored.items() if ":" + p in pkg_shaders.files}
    has_asset_contributions = (
        bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders)
    )

    # Computed once, before the branch: which generator runs depends on the
    # pubspec, but a build hook is a property of the package either way.
    unreplaced_hook = _detect_unreplaced_hook(ctx)

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content = ""
    overlay_android_content = ""
    for overlay_label in ctx.attr.overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            ctx.attr.package_name,
            ctx.attr.version,
            language_version,
            dep_labels,
            license_file,
        )
        if overlay_content:
            # Look up the matching `android/BUILD.bazel.tpl` from the same
            # overlay root. Plugins whose Android side has real sources
            # ship one alongside the top-level BUILD; plugins that don't
            # leave it absent and the empty-stub fallback fires below.
            overlay_android_content = _resolve_overlay_template(
                ctx,
                overlay_label,
                ctx.attr.package_name,
                ctx.attr.version,
                language_version,
                dep_labels,
                "android/BUILD.bazel.tpl",
            )
            break

    if overlay_content:
        ctx.file("BUILD.bazel", overlay_content)
        ctx.file(MEMBER_FILE, json.encode({"kind": MEMBER_OVERLAY, "material_icons": False, "android_lib": False}))

        # When the overlay ships an `android/BUILD.bazel.tpl`, use it
        # verbatim: the overlay's own plugin target names its `:lib` as its
        # `exports` (audio_session declares Android sources and ships the
        # full sub-package; objective_c is pure Apple and ships none).
        #
        # An overlay's Android library still depends on the artifacts the
        # plugin's Gradle build declares, so they join the hub's Maven data
        # and its `maven_artifacts` block. Lines the parser cannot read are
        # what the overlay replaces, so they are not reported.
        overlay_maven_deps = []
        if overlay_android_content:
            overlay_maven_deps = _maven_dep_dicts(_read_plugin_maven_deps(ctx))
        _write_maven_deps(ctx, overlay_maven_deps, [])
        if overlay_android_content:
            ctx.file("android/BUILD.bazel", overlay_android_content)
        return ctx.repo_metadata(reproducible = True)

    if plugin_block.present:
        # Detect Apple sources per platform when pluginClass is set.
        apple_macos_srcs_dirs = []
        apple_ios_srcs_dirs = []

        macos_info = plugin_block.platforms.get("macos", {})
        ios_info = plugin_block.platforms.get("ios", {})
        linux_info = plugin_block.platforms.get("linux", {})
        windows_info = plugin_block.platforms.get("windows", {})

        macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
        ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

        apple_macos_include_dirs = []
        apple_ios_include_dirs = []
        apple_macos_privacy_manifests = []
        apple_ios_privacy_manifests = []

        if macos_info and macos_info.get("pluginClass", ""):
            _fail_on_swiftpm_dependencies(
                ctx,
                ctx.attr.package_name,
                "macos",
                macos_shared_darwin,
            )
            apple_macos_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "macos",
                macos_shared_darwin,
            )
            apple_macos_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_macos_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_macos_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_macos_srcs_dirs,
            )

        if ios_info and ios_info.get("pluginClass", ""):
            _fail_on_swiftpm_dependencies(
                ctx,
                ctx.attr.package_name,
                "ios",
                ios_shared_darwin,
            )
            apple_ios_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "ios",
                ios_shared_darwin,
            )
            apple_ios_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_ios_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_ios_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_ios_srcs_dirs,
            )

        # Linux/Windows desktop sources: scan whenever pluginClass is
        # set on that platform. The plugin's own `linux/`/`windows/`
        # directory is the canonical location.
        linux_src_dir = ""
        windows_src_dir = ""
        if linux_info and linux_info.get("pluginClass", ""):
            linux_src_dir = _detect_desktop_source_dir(ctx, "linux")
        if windows_info and windows_info.get("pluginClass", ""):
            windows_src_dir = _detect_desktop_source_dir(ctx, "windows")
        linux_link = _read_desktop_link_libraries(ctx, "linux") if linux_src_dir else None
        windows_link = _read_desktop_link_libraries(ctx, "windows") if windows_src_dir else None

        # Android sources: scan when pluginClass is set on android.
        android_info = plugin_block.platforms.get("android", {})
        android_src_dir = ""
        android_java_package = ""
        android_gradle_maven = None
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False
        if android_info:
            android_native_build = _detect_android_native_build(ctx)
        if android_info and android_info.get("pluginClass", ""):
            android_src_dir = _detect_android_source_dir(ctx)
            android_has_resources = _detect_android_resources(ctx)

            # Namespace resolution mirrors AGP (gradle `android.namespace`,
            # else the manifest `package` attribute). The pubspec's
            # `package` field locates the plugin class for the registrant;
            # it only stands in for the namespace when the plugin declares
            # none of its own.
            android_java_package = _checked_java_package(
                ctx.attr.package_name,
                "android/build.gradle(.kts), android/src/main/AndroidManifest.xml or pubspec.yaml",
                (
                    _detect_android_namespace(ctx) or
                    android_info.get("package", "") or
                    ""
                ),
            )
            if android_src_dir or android_has_resources:
                android_gradle_maven = _read_plugin_maven_deps(ctx)
                android_manifest = _detect_android_manifest(ctx)
                android_consumer_proguard_specs = _detect_consumer_proguard_specs(ctx)

        plugin_platforms_json = json.encode(plugin_block.platforms)
        build_content = make_flutter_member_build_content(
            name = ctx.attr.package_name,
            language_version = language_version,
            version = ctx.attr.version,
            license_file = license_file,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            plugin_platforms_json = plugin_platforms_json,
            apple_macos_srcs_dirs = apple_macos_srcs_dirs,
            apple_ios_srcs_dirs = apple_ios_srcs_dirs,
            apple_macos_include_dirs = apple_macos_include_dirs,
            apple_ios_include_dirs = apple_ios_include_dirs,
            apple_macos_privacy_manifests = apple_macos_privacy_manifests,
            apple_ios_privacy_manifests = apple_ios_privacy_manifests,
            linux_src_dir = linux_src_dir,
            windows_src_dir = windows_src_dir,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets.files,
            pkg_asset_platforms = pkg_assets.platforms,
            pkg_shaders = pkg_shaders.files,
            pkg_shader_platforms = pkg_shaders.platforms,
            additional_licenses = additional_licenses,
            pkg_asset_flavors = pkg_asset_flavors,
            pkg_shader_flavors = pkg_shader_flavors,
            linux_link = linux_link,
            windows_link = windows_link,
            has_android_lib = bool(android_src_dir or android_has_resources or android_native_build),
        )
    elif has_asset_contributions or uses_material_icons or additional_licenses:
        # No plugin block, but the pubspec has flutter.fonts/assets/shaders (or
        # asks for the Material icon font). A Flutter member (rather than
        # rules_dart's) so the metadata propagates via
        # FlutterInfo.pub_fonts/pub_assets/pub_shaders to the consuming app's
        # bundle aggregator.
        build_content = make_flutter_member_build_content(
            name = ctx.attr.package_name,
            language_version = language_version,
            version = ctx.attr.version,
            license_file = license_file,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets.files,
            pkg_asset_platforms = pkg_assets.platforms,
            pkg_shaders = pkg_shaders.files,
            pkg_shader_platforms = pkg_shaders.platforms,
            additional_licenses = additional_licenses,
            pkg_asset_flavors = pkg_asset_flavors,
            pkg_shader_flavors = pkg_shader_flavors,
        )
        android_src_dir = ""
        android_java_package = ""
        android_gradle_maven = None
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False
    else:
        build_content = make_dart_member_build_content(
            name = ctx.attr.package_name,
            language_version = language_version,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            version = ctx.attr.version,
            license_file = license_file,
        )
        android_src_dir = ""
        android_java_package = ""
        android_gradle_maven = None
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False

    ctx.file("BUILD.bazel", build_content)
    is_flutter_member = plugin_block.present or has_asset_contributions or uses_material_icons or bool(additional_licenses)
    ctx.file(MEMBER_FILE, json.encode({
        "kind": MEMBER_FLUTTER if is_flutter_member else MEMBER_DART,
        "material_icons": uses_material_icons,
        "android_lib": bool(android_src_dir or android_has_resources or android_native_build),
    }))

    # `android/BUILD.bazel` exists for a package with an Android library: the
    # member selects its `:lib` on Android, so non-Android workspaces don't
    # load it or pay the @rules_android / @rules_kotlin cost. Plugins whose
    # Gradle build compiles native Android code that autogen cannot translate
    # get a load-time fail() here instead: an Android app that links one
    # breaks loudly rather than shipping an APK missing the library.
    #
    # Gradle dependencies the reader cannot translate are recorded, not
    # failed on here: the library is written as for the ones it can read, and
    # the application that links the plugin fails, naming the lines with
    # everything else it lacks (`flutter_android_plugin_libs`).
    maven_deps = []
    maven_errors = []
    if android_gradle_maven and not android_native_build:
        maven_deps = _maven_dep_dicts(android_gradle_maven)
        maven_errors = android_gradle_maven.errors
    if android_native_build:
        ctx.file("android/BUILD.bazel", _make_android_native_build_unsupported_content(
            ctx.attr.package_name,
            ctx.attr.version,
        ))
    elif android_src_dir or android_has_resources:
        ctx.file("android/BUILD.bazel", make_android_subpackage_build_content(
            android_src_dir = android_src_dir,
            java_package = android_java_package,
            maven_deps = maven_deps,
            android_manifest = android_manifest,
            consumer_proguard_specs = android_consumer_proguard_specs,
            has_resources = android_has_resources,
        ))
    _write_maven_deps(ctx, maven_deps, maven_errors)
    return ctx.repo_metadata(reproducible = True)

flutter_pub_package = repository_rule(
    implementation = _flutter_pub_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name, or the name of the Flutter SDK package under `packages/` of the Flutter source.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version, as pubspec.lock records it (`0.0.0` for an SDK package). Downloaded when `flutter_source_version` is empty.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the archive fetched: the package's, as pubspec.lock records it, or, with `flutter_source_version`, the Flutter source tarball's (`flutter_source_sha256`). Mandatory for both: nothing is downloaded without one. Unused for a git package.",
            default = "",
        ),
        "git_url": attr.string(
            doc = "A git package's repository: `description.url` in the lock. When set, the package is fetched from it at `resolved_ref` instead of downloaded.",
            default = "",
        ),
        "resolved_ref": attr.string(
            doc = "A git package's locked commit: `description.resolved-ref`, a full commit id.",
            default = "",
        ),
        "git_path": attr.string(
            doc = "A git package's directory in the repository: `description.path`.",
            default = ".",
        ),
        "lock": attr.label(
            doc = "The lock, against whose directory a relative `git_url` is resolved, as pub resolves it. Read only for a relative `git_url`.",
            allow_single_file = True,
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository. Ignored with `flutter_source_version`.",
            default = "https://pub.dev",
        ),
        "framework_json": attr.label(
            doc = "The `flutter_framework.json` of a framework source holding this package as `packages/<package_name>`, " +
                  "for a Flutter SDK package of an SDK whose framework is not the release.",
            allow_single_file = True,
        ),
        "sdk": attr.string(
            doc = "For a Flutter SDK package, the SDK whose framework it is from, for messages.",
            default = "flutter",
        ),
        "prefix": attr.string(
            doc = "The prefix of the index the package is planned against: the build's, or another SDK framework's.",
            default = "flutter_pub",
        ),
        "flutter_source_version": attr.string(
            doc = "The Flutter version whose pinned source tarball holds this package as `packages/<package_name>`, for a Flutter SDK package " +
                  "(`source: sdk` in the lock). When empty, the package is downloaded from a pub registry.",
            default = "",
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook. Resolved by the extension from " +
                  "rules_dart's curated registry, so a user depending on, say, " +
                  "`drift` never names `sqlite3`. Attached to the generated " +
                  "package target rather than to the application, which is what " +
                  "makes them propagate the way pub's own assets do.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant. Without it, a " +
                  "package shipping a hook that nothing replaces is recorded and " +
                  "the application that reaches it fails, rather than building " +
                  "cleanly and dying at runtime on an unresolved native symbol.",
            default = False,
        ),
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees. Each label points at " +
                  "an `ext/BUILD.bazel` (or equivalent) that anchors a directory " +
                  "tree of `<package>/<version>/BUILD.bazel.tpl` overrides. The " +
                  "rule walks the roots in order and uses the first match. " +
                  "User-supplied roots come before the bundled " +
                  "`@rules_flutter//ext:BUILD.bazel`.",
            allow_files = True,
            default = [],
        ),
    },
    doc = "Downloads a single Flutter pub package, its source repository, and emits its member: a `flutter_pub_member` (a plugin when `flutter.plugin` is present, otherwise a package bundling fonts, assets or shaders) or rules_dart's `pub_package_member` (for a package with nothing of Flutter's). When Apple sources are detected, also emits per-platform `flutter_apple_plugin_library` sub-targets. Honors per-package overlay BUILD.bazel.tpl overrides under `overlay_roots`, which replace the member with a whole target. The package's library repository (`flutter_pub_library_repo`) builds the member with the others of its dependency cycle. The `flutter pub get` analog of `pub_lock_package`.",
)
