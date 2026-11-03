"""Flutter rules for Android builds.

Two tiers of API:

    Tier 1 — flutter_android_app (self-contained, recommended):

        load("@rules_flutter//flutter:android.bzl", "flutter_android_app")
        load("@rules_flutter//flutter:defs.bzl", "flutter_application")

        flutter_application(name = "my_app", main = "lib/main.dart", deps = [...])

        flutter_android_app(
            name = "my_app_android",
            application = ":my_app",
            package_name = "com.example.myapp",
        )

    Prerequisites: run `flutter create --platforms=android .` in your package to
    generate the conventional `android/app/src/main/` directory with
    AndroidManifest.xml, resources, and Kotlin sources. The macro handles everything
    automatically — no edits to the flutter create output needed.

    Tier 2 — composable rules (advanced, full control):

        load("@rules_flutter//flutter:android.bzl",
            "ANDROID_MIN_SDK_VERSION",
            "ANDROID_TARGET_SDK_VERSION",
            "flutter_android_build",
            "flutter_android_bundle",
            "flutter_android_engine",
            "flutter_android_manifest_gen",
            "flutter_android_manifest_merge",
            "flutter_android_runner_lib_gen")

        flutter_android_bundle(name = "my_bundle", application = ":my_app")
        filegroup(name = "my_native_libs_files", srcs = [":my_bundle"], output_group = "native_libs")
        cc_library(name = "my_native_libs", srcs = [":my_native_libs_files"])
        flutter_android_engine(name = "my_engine")
        flutter_android_manifest_gen(name = "my_manifest", package_name = "com.example.myapp")

        flutter_android_runner_lib_gen(
            name = "my_runner",
            package_name = "com.example.myapp",
            engine = ":my_engine",
        )

        android_binary(
            name = "my_apk",
            manifest = ":my_manifest",
            deps = [":my_native_libs", ":my_engine", ":my_runner"],
        )
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", _android_binary = "android_binary", _android_library = "android_library")
load("@rules_cc//cc:cc_library.bzl", _cc_library = "cc_library")
load("@rules_java//java:java_import.bzl", _java_import = "java_import")
load("@rules_kotlin//kotlin:android.bzl", _kt_android_library = "kt_android_library")
load("//flutter/private:constants.bzl", _ANDROID_MIN_SDK_VERSION = "ANDROID_MIN_SDK_VERSION", _ANDROID_TARGET_SDK_VERSION = "ANDROID_TARGET_SDK_VERSION")
load("//flutter/private:flutter_android_application.bzl", _flutter_android_bundle = "flutter_android_bundle")
load("//flutter/private:flutter_android_build.bzl", _flutter_android_build = "flutter_android_build")
load("//flutter/private:flutter_android_manifest_merge.bzl", _flutter_android_manifest_merge = "flutter_android_manifest_merge")
load("//flutter/private:flutter_android_plugin_library.bzl", _flutter_android_plugin_library = "flutter_android_plugin_library")
load("//flutter/private:flutter_android_registrant.bzl", _flutter_android_registrant = "flutter_android_registrant")

# Re-export constants for user BUILD files.
ANDROID_MIN_SDK_VERSION = _ANDROID_MIN_SDK_VERSION
ANDROID_TARGET_SDK_VERSION = _ANDROID_TARGET_SDK_VERSION

# AndroidX deps of flutter.jar, mirroring the dependency list of Flutter's
# official io.flutter:flutter_embedding_* Maven POM (the deps every
# Gradle-built Flutter app ships): lifecycle for FlutterActivity's
# LifecycleRegistry, window/window-java for foldable display features, core
# for ContextCompat/ViewCompat/input, tracing for the engine's TraceSection,
# fragment for FlutterFragment(Activity), exifinterface for image decoding,
# and relinker for engine .so loading. The POM's lifecycle-common-java8 and
# lifecycle-process entries are omitted: at the lifecycle version pinned here
# their classes live in lifecycle-common, and the embedding never references
# lifecycle-process types.
#
# `flutter_android_engine` *exports* these: the POM declares them at compile
# scope, so in Gradle builds everything that compiles against the embedding
# AAR — runner sources, the plugin registrant, and every Flutter plugin —
# sees them on its compile classpath transitively. Exporting reproduces
# that contract. It adds nothing to the APK that the engine target wasn't
# already carrying at runtime.
_ANDROIDX_EMBEDDING_DEPS = [
    "@rules_android_maven//:androidx_annotation_annotation",
    "@rules_android_maven//:androidx_core_core",
    "@rules_android_maven//:androidx_exifinterface_exifinterface",
    "@rules_android_maven//:androidx_fragment_fragment",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "@rules_android_maven//:androidx_tracing_tracing",
    "@rules_android_maven//:androidx_window_window",
    "@rules_android_maven//:androidx_window_window_java",
    "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
]

# -- Composable rules (Tier 2) ------------------------------------------------

def _android_only():
    """`target_compatible_with` for a target built only for Android arm64 or x86_64.

    A target that takes its ABI from the platform it is built for has nothing to
    build on any other, so a wildcard on a non-Android platform skips it rather
    than failing on it. Its dependents are skipped with it.
    """
    return select({
        "@rules_flutter//flutter/private:android_arm64": [],
        "@rules_flutter//flutter/private:android_x64": [],
        "//conditions:default": [Label("@platforms//:incompatible")],
    })

def flutter_android_bundle(name, **kwargs):
    """Bundles Flutter compilation outputs for Android packaging.

    See `flutter/private/flutter_android_application.bzl` for the rule. The
    bundle is built for the Android platform `android_binary` builds it for, so
    it is incompatible with any other platform: `bazel build //...` on a host
    platform skips it, with no `manual` tag.

    Args:
        name: Target name.
        **kwargs: Arguments of the rule: `application`, `mobile_install_compatible`,
            and the common ones (`tags`, `visibility`, ...).
    """
    kwargs["target_compatible_with"] = kwargs.pop("target_compatible_with", []) + _android_only()
    _flutter_android_bundle(name = name, **kwargs)

# Builds targets for given Android platforms, whatever the command line asked
# for: a test of an APK for one ABI, or several, in a plain `bazel test //...`.
flutter_android_build = _flutter_android_build

# Merges a variant AndroidManifest.xml overlay (e.g. flutter create's
# android/app/src/debug/AndroidManifest.xml) into a base manifest — the
# Bazel counterpart of Gradle's per-variant manifest merge. Wired
# automatically by flutter_android_app; expose for Tier-2 control.
flutter_android_manifest_merge = _flutter_android_manifest_merge

def flutter_android_permissions_manifest(name, permissions, **kwargs):
    """Writes an overlay manifest declaring `permissions`, and nothing else.

    The overlay half of the additive permission seam: pair it with
    `flutter_android_manifest_merge` to add `<uses-permission>` elements to
    any base manifest — including one produced by
    `flutter_android_manifest_gen`, which has no permission attribute of its
    own. `flutter_android_app(permissions = [...])` composes exactly these
    two rules; do it by hand when assembling an `android_binary` yourself.

    Args:
        name: Target name. Pass as `overlay` to
            `flutter_android_manifest_merge`.
        permissions: Fully-qualified permission names, e.g.
            `["android.permission.INTERNET"]`.
        **kwargs: Additional arguments (e.g. visibility, tags). `tags`
            defaults to `["manual"]`.
    """
    if not permissions:
        fail("flutter_android_permissions_manifest(name = %r): `permissions` " % name +
             "is empty. Drop the target rather than merging nothing.")
    tags = kwargs.pop("tags", ["manual"])
    write_file(
        name = name,
        out = "%s/AndroidManifest.xml" % name,
        content = [
            "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\">",
        ] + [
            "    <uses-permission android:name=\"%s\"/>" % permission
            for permission in permissions
        ] + [
            "</manifest>",
            "",
        ],
        tags = tags,
        **kwargs
    )

# Public wrapper that compiles a Flutter plugin's Android Kotlin/Java sources
# into a kt_android_library. For pub.dev plugins, flutter_pub_package emits
# this automatically; expose it here so users can wire a monorepo plugin's
# BUILD.bazel without going through the ext/ overlay system.
flutter_android_plugin_library = _flutter_android_plugin_library

# Registrant rule that emits GeneratedPluginRegistrant.java from a
# flutter_application's transitive FlutterInfo. Wired automatically by
# flutter_android_app; expose for Tier-2 control.
flutter_android_registrant = _flutter_android_registrant

# The engine of each ABI an APK can be built for, by the CPU of the platform
# `android_binary` builds that copy of its dependencies for. The labels are the
# caller's, as the macro's other repository labels are, so a workspace that
# builds an ABI names that engine's repository in its `use_repo`.
_ENGINE_FOR_CPU = {
    "@rules_flutter//flutter/private:android_arm64": ["@flutter_android_engine_arm64//:stripped"],
    "@rules_flutter//flutter/private:android_x64": ["@flutter_android_engine_x64//:stripped"],
}

_NO_ENGINE_FOR_PLATFORM = (
    "flutter_android_engine is built for a platform that is not Android arm64 " +
    "or x86_64. An Android app is built for the platforms of --@rules_android//flags:android_platforms: " +
    "pass --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a " +
    "(and :x86_64 for a second ABI), or build it through flutter_android_build."
)

def flutter_android_engine(name, neverlink = False, **kwargs):
    """Imports the Flutter engine (flutter.jar) as an android_library target.

    The engine is the one of the platform the target is built for. An
    `android_binary` builds its dependencies once for each platform of
    `--@rules_android//flags:android_platforms`, so an APK for several ABIs carries the engine of
    each, and a target built for neither Android arm64 nor x86_64 fails. The
    repository of each ABI you build for goes in your `use_repo`
    (`flutter_android_engine_arm64`, `flutter_android_engine_x64`).

    Auto-selects the engine of the build mode:
    - Debug (-c dbg): JIT engine for emulator/iterative development.
    - Profile (-c opt with --@rules_flutter//flutter:profile): AOT engine
      with the Dart VM service.
    - Release (-c opt / default): AOT engine for production.

    The engine's native libraries are stripped with the NDK's `llvm-strip
    --strip-unneeded`, as a Gradle build strips them, so the Android NDK
    C++ toolchain must be registered (see the README's Android section).

    A plugin library compiles against the engine but must not package it:
    the app's own engine, of the app's ABI, is the one that ships. Give a
    plugin a `neverlink = True` engine, as Gradle gives a plugin the
    embedding with `compileOnly`. A linked one puts a second engine in the
    APK, which for an x64 app is an arm64 `libflutter.so` that makes Android
    install the app as arm64 and crash at launch.

    Args:
        name: Target name. Add to android_binary deps.
        neverlink: Compile against the engine without packaging it. For
            `flutter_android_plugin_library(flutter_engine = ...)`; the
            engine in the app's `android_binary` deps leaves it False.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])

    # The engine of an ABI exists for platforms of that ABI only.
    compatible_with = kwargs.pop("target_compatible_with", [])
    if not neverlink:
        compatible_with = compatible_with + _android_only()

    # A neverlink engine is compiled against, and its classes are the same for
    # every ABI, so it is the arm64 engine whatever platform the plugin is
    # built for. That keeps a plugin library buildable on its own, with no
    # Android platform.
    if neverlink:
        engine = ["@flutter_android_engine_arm64//:stripped"]
    else:
        engine = select(_ENGINE_FOR_CPU, no_match_error = _NO_ENGINE_FOR_PLATFORM)

    # `deps` (not just the wrapper's exports) matters here: flutter.jar's
    # own desugar action takes its classpath from the java_import's
    # direct deps, and desugaring io.flutter.* against an incomplete
    # classpath fails the deploy jar's desugar-dependency check.
    #
    # The jar holds the classes. The engine's libraries are not in it, and
    # reach the APK as the engine target's AndroidNativeLibsInfo (below).
    _java_import(
        name = "_%s_jar" % name,
        # The engine repo's `stripped` follows the build mode, and fetches
        # the profile engine's repo only in a profile build.
        jars = engine,
        tags = tags,
        neverlink = neverlink,
        target_compatible_with = compatible_with,
        deps = _ANDROIDX_EMBEDDING_DEPS,
    )

    # The android_library wrapper carries the embedding's R8 keep rules
    # (the @androidx.annotation.Keep contract FlutterJNI relies on) to the
    # consuming android_binary — the role the Maven embedding AAR's
    # consumer proguard config plays in Gradle builds. java_import cannot
    # declare proguard_specs, hence the wrapper. The androidx artifacts
    # are additionally exported so consumers compile against the same
    # classpath the embedding POM gives Gradle builds (see
    # _ANDROIDX_EMBEDDING_DEPS).
    #
    # The engine's libraries are the exports an APK packages and a plugin's
    # compile does not need.
    _android_library(
        name = name,
        exports = ["_%s_jar" % name] + _ANDROIDX_EMBEDDING_DEPS + ([] if neverlink else engine),
        proguard_specs = ["@rules_flutter//flutter/private/runners/android:flutter_engine_proguard.pro"],
        neverlink = neverlink,
        tags = tags,
        target_compatible_with = compatible_with,
        **kwargs
    )

def flutter_android_manifest_gen(
        name,
        package_name,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        **kwargs):
    """Generates an AndroidManifest.xml from the default Bazel template.

    The template uses FlutterActivity as the main activity with embedding v2.

    Debug builds (`-c dbg`) declare `android.permission.INTERNET`, matching
    the permission Gradle merges from flutter create's debug variant
    manifest: Android enforces INTERNET at the kernel level (AID_INET group
    membership), so without it the Dart VM service cannot bind even its
    loopback socket and debugging/hot reload are impossible. Release builds
    declare no permissions.

    That grant is the *debugger's*, not the app's, and this template has a
    fixed key set with no permission attribute. An app that networks in
    release declares it for itself — through
    `flutter_android_app(permissions = [...])`, or, when assembling an
    `android_binary` by hand, by composing this manifest with
    `flutter_android_permissions_manifest` +
    `flutter_android_manifest_merge`:

        flutter_android_manifest_gen(name = "base", package_name = "...")
        flutter_android_permissions_manifest(
            name = "extra",
            permissions = ["android.permission.INTERNET"],
        )
        flutter_android_manifest_merge(
            name = "manifest",
            base = ":base",
            overlay = ":extra",
        )

    Args:
        name: Target name. Pass to android_binary manifest.
        package_name: Android package name (e.g. "com.example.myapp").
        app_name: Display name for the app. Defaults to package_name.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        **kwargs: Additional arguments (e.g. visibility, tags).
    """
    tags = kwargs.pop("tags", ["manual"])
    display_name = app_name or package_name

    substitutions = {
        "PACKAGE_NAME": package_name,
        "APP_NAME": display_name,
        "MIN_SDK_VERSION": min_sdk_version,
        "TARGET_SDK_VERSION": target_sdk_version,
    }

    expand_template(
        name = "__%s_dbg" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_dbg/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "<uses-permission android:name=\"android.permission.INTERNET\"/>",
        },
        tags = tags,
    )

    expand_template(
        name = "__%s_opt" % name,
        template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
        out = "__%s_opt/AndroidManifest.xml" % name,
        substitutions = substitutions | {
            "INTERNET_PERMISSION": "",
        },
        tags = tags,
    )

    native.alias(
        name = name,
        actual = select({
            "@rules_flutter//flutter/private:dbg": "__%s_dbg" % name,
            # Profile serves the VM service too, so it needs the socket.
            "@rules_flutter//flutter/private:profile": "__%s_dbg" % name,
            "//conditions:default": "__%s_opt" % name,
        }),
        tags = tags,
        **kwargs
    )

def flutter_android_runner_lib_gen(
        name,
        package_name,
        engine,
        manifest = None,
        **kwargs):
    """Generates a kt_android_library with a default Flutter runner Activity.

    Uses template MainActivity.kt from rules_flutter. This provides a
    custom Activity subclass for users who don't have `flutter create`
    output but want a named Activity class (e.g. for deep links or
    intent filters).

    For most apps, FlutterActivity can be used directly in the manifest
    without a custom runner — see flutter_android_manifest_gen.

    Args:
        name: Target name. Add to android_binary deps.
        package_name: Android package name (e.g. "com.example.myapp").
            Used for template substitution in MainActivity.kt.
        engine: A flutter_android_engine target (flutter.jar).
        manifest: AndroidManifest.xml for the library. If not provided,
            a minimal one is generated.
        **kwargs: Additional arguments passed to kt_android_library.
    """
    tags = kwargs.pop("tags", ["manual"])

    # Generate the MainActivity.kt with the correct package name.
    expand_template(
        name = "__%s_main_activity" % name,
        template = "@rules_flutter//flutter/private/runners/android:MainActivity.kt",
        out = "__%s_runner/MainActivity.kt" % name,
        substitutions = {
            "PACKAGE_NAME": package_name,
        },
        tags = tags,
    )

    # Generate a minimal manifest for android_library if not provided.
    actual_manifest = manifest
    if not actual_manifest:
        expand_template(
            name = "__%s_lib_manifest" % name,
            template = "@rules_flutter//flutter/private/runners/android:AndroidManifest.xml",
            out = "__%s_lib_manifest/AndroidManifest.xml" % name,
            substitutions = {
                "PACKAGE_NAME": package_name,
                "APP_NAME": package_name,
                "MIN_SDK_VERSION": ANDROID_MIN_SDK_VERSION,
                "TARGET_SDK_VERSION": ANDROID_TARGET_SDK_VERSION,
                # Never a permission here: this is a LIBRARY manifest, and
                # rules_android's merger strips library permissions unless
                # --merge_android_manifest_permissions is set — the permission
                # would silently come and go with a flag. The binary manifest
                # (flutter_android_manifest_gen) owns INTERNET.
                "INTERNET_PERMISSION": "",
            },
            tags = tags,
        )
        actual_manifest = "__%s_lib_manifest" % name

    _kt_android_library(
        name = name,
        srcs = ["__%s_main_activity" % name],
        manifest = actual_manifest,
        tags = tags,
        deps = [engine],
        **kwargs
    )

def _variant_overlay(name, variant, manifest, base_manifest):
    """Resolves a `flutter create` variant manifest (`debug` or `profile`).

    Args:
        name: The flutter_android_app name, for error messages.
        variant: The build variant directory under android/app/src/.
        manifest: The macro argument: False, None (discover) or a label.
        base_manifest: The main manifest the variant merges into, or None.

    Returns:
        The overlay manifest, or None.
    """
    if manifest == False:
        return None
    if manifest == None:
        # `allow_empty`: a variant overlay is optional; most apps have none.
        discovered = native.glob(
            ["android/app/src/%s/AndroidManifest.xml" % variant],
            allow_empty = True,
        )
        overlay = discovered[0] if discovered else None
    else:
        overlay = manifest
    if overlay != None and base_manifest == None:
        fail(
            ("flutter_android_app(name = %r): %s variant manifest %r has no main " +
             "manifest to merge into. Add android/app/src/main/AndroidManifest.xml " +
             "(flutter create output), pass `manifest`, or pass " +
             "`%s_manifest = False` to ignore the variant manifest.") %
            (name, variant, overlay, variant),
        )
    return overlay

# -- Convenience macro (Tier 1) -----------------------------------------------

def flutter_android_app(
        name,
        application,
        package_name,
        app_name = None,
        min_sdk_version = ANDROID_MIN_SDK_VERSION,
        target_sdk_version = ANDROID_TARGET_SDK_VERSION,
        manifest = None,
        debug_manifest = None,
        profile_manifest = None,
        permissions = [],
        resources = [],
        deps = [],
        pub_hub_name = "deps",
        namespace = None,
        **kwargs):
    """Builds a Flutter Android APK from a flutter_application target.

    Discovers runner files from the conventional `android/app/src/main/`
    directory (as generated by `flutter create --platforms=android .`) and
    wires up all internal targets automatically.

    The ABIs of the APK are those of `--@rules_android//flags:android_platforms`, as for any
    `android_binary`: one platform builds an APK for that ABI, several build one
    APK for all of them (`flutter build apk`'s fat APK). The Flutter engine, the
    app's `libapp.so`, the AARs' native libraries and any C++ deps are each
    packaged for every ABI. Name the platforms rules_android ships,
    `@rules_android//:arm64-v8a` and `@rules_android//:x86_64`:

        bazel build //:my_app_android --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a

    With no `--@rules_android//flags:android_platforms`, rules_android builds for `--platforms`, the
    host's, and the build fails naming the flag. To fix the ABI of a target
    regardless of the command line, as a test does, wrap it in
    `flutter_android_build`.

    Three modes, and which one an app is in decides what it can express:
      1. `manifest` provided → uses it directly, with **no** `${...}`
         placeholder preprocessing and no resource/Kotlin auto-discovery.
         Handing this attribute the same `android/app/src/main/`
         AndroidManifest.xml mode 2 would have discovered therefore fails —
         `flutter create` writes `android:name="${applicationName}"` and
         nothing substitutes it. Use mode 2 for `flutter create` output;
         mode 1 is for a manifest you wrote yourself.
      2. android/app/src/main/AndroidManifest.xml found → uses flutter create
         manifest (preprocessed for Gradle variables), discovers resources
         and Kotlin sources from android/app/src/main/. The main manifest is
         used in **every** compilation mode.
      3. No manifest found → generates manifest from template.

    `permissions` adds `<uses-permission>` elements to the effective manifest
    in every mode and every compilation mode, so it is the answer in all
    three — see the attribute's documentation below.

    Debug variant manifests (the Gradle merge Bazel lacks): flutter create
    declares `android.permission.INTERNET` only in
    `android/app/src/debug/AndroidManifest.xml`. Without it a debug APK
    cannot host the Dart VM service (Android enforces INTERNET at the
    kernel level via AID_INET), so hot reload and debugging are impossible.
    This macro folds the debug variant into `-c dbg` APKs, controlled by
    `debug_manifest`:
      - None (default) → discover android/app/src/debug/AndroidManifest.xml;
        when present, its permissions are merged into the main manifest for
        `-c dbg` builds only. Requires a main manifest (mode 1 or 2).
      - a label → merge that variant manifest instead of discovering one.
      - False → no debug variant handling, even if the file exists.
    Release (`-c opt`, the default) APKs always use the main manifest
    unchanged — so a `flutter create` app that networks perfectly in `-c dbg`
    has **no** `INTERNET` permission in release, and Android enforces that at
    the kernel level (AID_INET group membership): every socket fails with
    `EACCES`, with no build error and no diagnostic. The dbg-only grant is a
    *debugging* requirement, not the app's network grant. An app that
    networks must declare it for itself, via `permissions`.
    `profile_manifest` does the same for profile builds (`-c opt` with
    `--@rules_flutter//flutter:profile`), from
    android/app/src/profile/AndroidManifest.xml, which `flutter create`
    writes with the `INTERNET` permission the VM service needs.

    The runner's sources, where Gradle looks for them (Kotlin under
    android/app/src/main/kotlin/ or java/, Java under java/, as
    `flutter create --android-language java` writes it), are compiled via
    kt_android_library with the Flutter engine and AndroidX deps.

    Plugin auto-wiring:
      - Generates a `flutter_android_registrant` target whose application is
        `application`, then compiles the resulting Java into a private
        `kt_android_library` that goes into `binary_deps`. Every plugin
        whose `flutter.plugin.platforms.android.pluginClass` is set ends up
        registered with the FlutterEngine on startup — no manual wiring.
      - Adds `@<pub_hub_name>//android:all_android_plugin_libs` to
        `binary_deps`, pulling in every transitively-resolved plugin
        spoke's Kotlin/Java sources (and resources) via the hub's
        aggregator. Spokes without Android sources contribute empty
        libraries (no-op).
      - Permissions that plugins and AARs declare in their own manifests
        (e.g. record_android's RECORD_AUDIO) are lifted into the app's
        manifest, as AGP merges them. Bazel's own merger drops library
        permissions unless `--merge_android_manifest_permissions` is set;
        the app no longer depends on that flag.

    Args:
        name: Target name (Bazel identifier). Produces an android_binary.
        application: A flutter_application target (required).
        package_name: The application id, e.g. "com.example.myapp"
            (required).
        namespace: The package the runner's code lives in, as Gradle's
            `namespace` (and AGP's R class package) in build.gradle.
            Defaults to `package_name`, which `flutter create` sets equal
            to it. Set it when the runner declares another package, e.g.
            one runner shipped under several application ids. The
            manifest's relative class names (`.MainActivity`,
            `.sub.Receiver`, a bare `MainActivity`) are written out in
            full against it, as AGP does; qualified names are untouched.
        app_name: User-facing display name. Defaults to name.
        min_sdk_version: Minimum Android SDK version.
        target_sdk_version: Target Android SDK version.
        manifest: Override AndroidManifest.xml. If not set, auto-discovered
            from android/app/src/main/ or generated from template.
        debug_manifest: Debug variant manifest merged into `-c dbg` APKs.
            None (default) discovers android/app/src/debug/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        profile_manifest: Profile variant manifest merged into profile APKs.
            None (default) discovers android/app/src/profile/AndroidManifest.xml;
            a label overrides discovery; False disables variant handling.
        permissions: Permission names — e.g.
            `["android.permission.INTERNET"]` — added to the effective
            manifest in **every** compilation mode and in all three manifest
            modes. This is what a networked app needs: `flutter create`
            grants `INTERNET` in the debug variant only, so without this the
            release APK cannot open a socket. A permission the manifest
            already declares is not duplicated. For a permission wanted in
            `-c dbg` alone, use `debug_manifest` instead; this attribute is
            consumed by the macro and cannot be a `select()`.
        resources: Extra resource_files for android_binary.
        deps: Extra deps for android_binary (e.g. custom android_library).
            A plugin written in the workspace goes here as its
            `flutter_android_plugin_library`: the registrant compiles
            against these too, so the plugin is both packaged and
            registered. Pub plugins arrive through the hub instead.
        pub_hub_name: Name of the `flutter.pub(name = ...)` hub providing
            plugin spokes. The macro depends on
            `@<pub_hub_name>//android:all_android_plugin_libs` to compile
            all plugin Kotlin/Java automatically. Defaults to `"deps"`,
            matching the convention in repo MODULE.bazel files. Set to
            `None` to opt out (e.g. for a workspace with no pub plugins).
        **kwargs: Passed through to android_binary.
    """
    display_name = app_name or name
    namespace = namespace or package_name
    tags = kwargs.pop("tags", ["manual"])

    # -- Internal targets (all __{name}_ prefixed) --
    #
    # The engine and the bundle are built for the Android platforms of the APK
    # that depends on them, once for each. On any other platform they are
    # incompatible, and so are the targets that depend on them, so a wildcard
    # skips them.

    # 1. Bundle Flutter outputs (libapp.so and the other native libraries +
    # flutter_assets). Built for each platform of --@rules_android//flags:android_platforms, as the
    # rest of android_binary's deps are.
    flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = application,
        tags = tags,
    )

    # 2. The bundle's native libraries, as a cc_library: the dep android_binary
    # takes the native libraries of each ABI it builds from.
    native.filegroup(
        name = "__%s_native_libs_files" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "native_libs",
        tags = tags,
    )
    _cc_library(
        name = "__%s_native_libs" % name,
        srcs = ["__%s_native_libs_files" % name],
        tags = tags,
    )

    # 4. Import Flutter engine.
    flutter_android_engine(
        name = "__%s_engine" % name,
        tags = tags,
    )

    # 5. Extract flutter_assets for inclusion in the APK.
    # The mobile_install output group has assets at assets/flutter_assets/.
    native.filegroup(
        name = "__%s_flutter_assets" % name,
        srcs = ["__%s_bundle" % name],
        output_group = "mobile_install",
        tags = tags,
    )

    # 6. Auto-wire the plugin registrant. Generates
    # `GeneratedPluginRegistrant.java` from the flutter_application's
    # transitive FlutterInfo plugin metadata, then wraps it in a
    # kt_android_library so the registrant class is on the runtime
    # classpath (called from the runner's MainActivity / FlutterActivity).
    #
    # The registrant references each plugin's `PluginClass` by fully
    # qualified name, so its compile classpath must include every
    # plugin's `kt_android_library`. We add the hub aggregator so the
    # plugin classes resolve at javac time too.
    _flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        tags = tags,
    )

    # `deps` too: a plugin written in the workspace reaches the app only
    # through them, and the registrant names its class.
    registrant_deps = ["__%s_engine" % name]
    if pub_hub_name:
        registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
    registrant_deps = registrant_deps + deps

    _kt_android_library(
        name = "__%s_registrant" % name,
        srcs = ["__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        tags = tags,
        deps = registrant_deps,
    )

    # 7. Resolve manifests (main + debug variant), resources, and Kotlin
    # sources.
    base_manifest = manifest
    binary_deps = [
        "__%s_native_libs" % name,
        "__%s_engine" % name,
        "__%s_registrant" % name,
    ]

    # 8. Plugin auto-wiring: compile every transitively-needed plugin's
    # Kotlin/Java via the hub's aggregator. Each spoke unconditionally
    # exposes `android:lib`; the hub's `all_android_plugin_libs` deps on
    # all of them. Spokes without Android sources contribute empty
    # libraries — no-op at link time, mechanical at the macro layer.
    if pub_hub_name:
        binary_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)

    if not base_manifest:
        # Try to discover flutter create output. `allow_empty`: an app
        # assembled without `flutter create`'s `android/` directory is a
        # supported case; the macro then needs the `base_manifest` argument.
        discovered_manifests = native.glob(
            ["android/app/src/main/AndroidManifest.xml"],
            allow_empty = True,
        )
        if discovered_manifests:
            # Flutter create case — preprocess manifest for Gradle variables.
            # Same pattern as flutter_ios_app preprocessing Info.plist for Xcode
            # variables (ios.bzl).
            expand_template(
                name = "__%s_manifest" % name,
                template = discovered_manifests[0],
                out = "__%s_AndroidManifest.xml" % name,
                substitutions = {
                    "${applicationName}": "android.app.Application",
                },
                tags = tags,
            )
            base_manifest = "__%s_manifest" % name

            # Discover resources from flutter create output. `allow_empty`:
            # an app may ship none.
            discovered_resources = native.glob(
                ["android/app/src/main/res/**"],
                allow_empty = True,
            )
            resources = list(resources) + discovered_resources

            # Discover and compile the runner from flutter create output:
            # Gradle's main source directories for Kotlin and Java. Not the
            # plugin registrant `flutter run` writes there: the
            # `__{name}_registrant` above is this app's. `allow_empty`: an app
            # may keep all of its code in Dart.
            runner_sources = native.glob(
                [
                    "android/app/src/main/kotlin/**/*.kt",
                    "android/app/src/main/java/**/*.java",
                    "android/app/src/main/java/**/*.kt",
                ],
                exclude = [
                    "android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java",
                ],
                allow_empty = True,
            )
            if runner_sources:
                _kt_android_library(
                    name = "__%s_runner" % name,
                    srcs = runner_sources,
                    custom_package = namespace,
                    tags = tags,
                    deps = ["__%s_engine" % name],
                )
                binary_deps.append("__%s_runner" % name)

    # Resolve the variant overlays — every state explicit:
    #   False → no variant handling, even if the file exists.
    #   None  → discover flutter create's variant manifest.
    #   label → use it, overriding discovery.
    debug_overlay = _variant_overlay(name, "debug", debug_manifest, base_manifest)
    profile_overlay = _variant_overlay(name, "profile", profile_manifest, base_manifest)

    if base_manifest == None:
        # No flutter create output — generate manifest from template. The
        # generated manifest handles the debug and profile INTERNET
        # permission itself (see flutter_android_manifest_gen).
        flutter_android_manifest_gen(
            name = "__%s_manifest" % name,
            package_name = package_name,
            app_name = display_name,
            min_sdk_version = min_sdk_version,
            target_sdk_version = target_sdk_version,
            tags = tags,
        )
        actual_manifest = "__%s_manifest" % name
    elif debug_overlay != None or profile_overlay != None:
        # Fold each variant's permissions into its own mode's APKs, the merge
        # Gradle performs per build type. Release APKs keep the main
        # manifest, byte-identical to a build without the variants.
        variants = {}
        for mode, overlay in [("dbg", debug_overlay), ("profile", profile_overlay)]:
            if overlay == None:
                continue
            flutter_android_manifest_merge(
                name = "__%s_manifest_merged_%s" % (name, mode),
                base = base_manifest,
                overlay = overlay,
                tags = tags,
            )
            variants["@rules_flutter//flutter/private:" + mode] = "__%s_manifest_merged_%s" % (name, mode)
        actual_manifest = select(variants | {"//conditions:default": base_manifest})
    else:
        actual_manifest = base_manifest

    # 8b. Add the app's own permissions to whatever manifest the mode
    # produced. Applied last and in every compilation mode, so a permission
    # the app needs cannot go missing from the release APK the way
    # `flutter create`'s debug-variant INTERNET does.
    if permissions:
        flutter_android_permissions_manifest(
            name = "__%s_permissions" % name,
            permissions = permissions,
            tags = tags,
        )
        flutter_android_manifest_merge(
            name = "__%s_manifest_with_permissions" % name,
            base = actual_manifest,
            overlay = "__%s_permissions" % name,
            tags = tags,
        )
        actual_manifest = "__%s_manifest_with_permissions" % name

    # 8c. Lift the permissions the app's Android libraries declare (plugins,
    # AARs) into its own manifest, as Gradle does. Bazel's merger drops them
    # unless --merge_android_manifest_permissions is set; done here, they
    # reach the APK whatever the flags.
    #
    # The same action writes the manifest's relative class names
    # (`.MainActivity`) in full against the namespace, as AGP does. Left
    # relative, Android resolves them against `package_name`, the application
    # id, which need not be the code's package: a second app shipping the
    # same runner under its own id would name a class that does not exist.
    flutter_android_manifest_merge(
        name = "__%s_manifest_with_library_permissions" % name,
        base = actual_manifest,
        libraries = binary_deps + deps,
        placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
        namespace = namespace,
        tags = tags,
    )
    actual_manifest = "__%s_manifest_with_library_permissions" % name

    # 9. Final android_binary.
    _android_binary(
        name = name,
        manifest = actual_manifest,
        manifest_values = {
            "applicationId": package_name,
            "minSdkVersion": min_sdk_version,
            "targetSdkVersion": target_sdk_version,
        },
        resource_files = resources if resources else None,
        assets = ["__%s_flutter_assets" % name],
        assets_dir = "assets",
        deps = binary_deps + deps,
        tags = tags,
        **kwargs
    )
