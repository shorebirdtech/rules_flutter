# rules_flutter

Bazel rules for building Flutter apps.

> **Status: beta.** It works today, but the public API may still change. Feedback and contributions are welcome.

rules_flutter compiles Dart to kernel or AOT native code, bundles assets, and packages the result for macOS, iOS, Android, Linux, Windows, and the web. It builds on [rules_dart](https://github.com/aran/rules_dart) for Dart compilation and hands platform packaging to the rulesets that already do it well: `rules_apple`, `rules_android`, and friends. It also ships a dev tool, `flutter_bazel`, that gives you hot reload, hot restart, and an HTTP channel for driving a running app from a script.

## Road to 1.0

This project is getting dangerously close to being good. It's still a beta, but
we're approaching parity with the native tools, getting good performance, and
successfully using it to build Flutter apps across several platforms. There have
been several PRs and forks. Of course, the process of using AI to build software
like this is more like sculpting than careful assembly. Here, the form is taking
shape. In the latest round of changes, we made as many breaking changes as we
could, in the hopes of reducing how many breaking changes will need to be made
going forward. I'm still not committed to avoiding breaking changes, but I think
it's fair to discuss what it'll take to ship a 1.0 where there will be an
expectation that APIs will remain stable for quite some time.

As context, there are varying degrees of success possible for this project, and
I don't know where it will land. One possibility is that it remains small, used
by myself and a couple of others for small-scale, largely non-professional
projects. In this world, I'll label it 1.0 as a retroactive, descriptive
process. That is, when a few months go by where development has been happening
but the APIs have remained stable, we'll assume that they can probably be kept
stable for some time going forward, and we'll label it 1.0. This is probably the
most likely outcome.

Somewhere else in the range of possibilities, this project could get picked up
for professional use by others. It could even attract attention, and we could
end up with actual collaboration with teams within Google and others in the
Flutter and Bazel ecosystem. In an optimistic case, two or three profitable
companies start using it in production, and Google is potentially even tacitly
supportive of it, or at least not hostile to it. In this scenario, the road to
1.0 will be a little more formal and aligned with the interests and
contributions of those companies. In that scenario, we'll probably see a formal,
published release cycle, likely tied closely to Dart, Flutter and Bazel release
cycles. 1.0 will be tagged with a consensus of the early production users.

Now, of course, everything can change quickly in this world. Google could change
the way it supports Flutter or Bazel. Dart 4 is on its way and may engender
changes to projects like these. Everyone's expectations should be set
accordingly. I welcome discussions of this direction by email or in
[GitHub issues](https://github.com/aran/rules_flutter/issues), and of course, if
you are using or considering using this project professionally, please contact
me so we can collaborate.

## Why build Flutter with Bazel

If `flutter build` works for you, here is what Bazel adds:

- **Reproducible builds.** Every input is tracked, so the same source produces the same output on every machine.
- **Remote caching.** Build outputs are content-addressed and shared across a team. A change to one package rebuilds only what depends on it.
- **Remote execution.** Compile on cloud workers, and build macOS, Linux, and Android targets from one `bazel build`.
- **One build graph.** Flutter apps, backend services, Rust and C++ libraries, and infrastructure code live together with real dependency tracking.
- **Native code without a second build system.** Depend on `cc_library`, `rust_shared_library`, or `swift_library` targets directly. No CMake, Gradle, or CocoaPods.
- **No build_runner.** Code generators such as json_serializable and freezed run as ordinary Bazel actions.

## Contents

- [Getting started](#getting-started)
- [Dependencies](#dependencies): pub packages, build hooks, native code
- [Building for each platform](#building-for-each-platform): macOS, iOS, Android, Linux, Windows, web, cross-compiling, release permissions
- [Custom engines and frameworks](#custom-engines-and-frameworks): a local flutter/flutter checkout and its engine, provenance, writing an engine source
- [Rules reference](#rules-reference): libraries, applications, tests, integration tests, plugins, code generation, providers
- [The dev tool](#the-dev-tool): running apps, hot reload, driving an app from a script
- [Examples](#examples)

## Getting started

### Requirements

| Platform | What you need |
|---|---|
| All | Bazel 9.3 or newer. The rules download Flutter 3.47.9 themselves; the supported releases are 3.47.x, and any other `flutter_version` fails naming the supported ones. |
| macOS | Xcode, for `rules_apple` and `rules_swift`. |
| iOS | A Mac with Apple silicon, and Xcode. rules_flutter builds iOS for arm64 only, so an Intel Mac's x86_64 simulator is not supported. The simulator needs no signing identity. A physical device does; see [Running on an iOS device](#running-on-an-ios-device). `flutter_bazel` screenshots, of a simulator or a device, need Xcode 27 or later, whose `devicectl` lists and captures screens and knows simulators (measured with Xcode 27.2, `devicectl` 651.32; earlier Xcodes were not tried). |
| Android | Nothing installed: hermetic_android_toolchains downloads the Android SDK and NDK. An installed SDK and NDK, at `ANDROID_HOME` and `ANDROID_NDK_HOME`, work instead. See [Android](#android). |
| Linux | A C++ toolchain. From macOS, an LLVM cross-toolchain. |
| Windows | MSVC for native builds. From macOS or Linux, a C++ cross-toolchain, debug builds only. |
| Web | Nothing extra. Compiling Dart to WASM or JavaScript is fully hermetic. |

### MODULE.bazel

```starlark
bazel_dep(name = "rules_flutter", version = "<latest from registry.bazel.build/modules/rules_flutter>")

# Your BUILD files load `dart_package_metadata` from rules_flutter. A project
# that also loads rules_dart's own rules (`dart_library`, `dart_analysis_options`)
# or names its flags needs this too, at the version rules_flutter's own
# MODULE.bazel names, or later:
# bazel_dep(name = "rules_dart", version = "<the version rules_flutter depends on>")

flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")
flutter.toolchain(flutter_version = "3.47.9")

flutter_pub = use_extension("@rules_flutter//flutter/pub:extensions.bzl", "pub")
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
)
use_repo(flutter_pub, "deps")
```

`flutter.toolchain` downloads the Flutter SDK and engine. Your root module's `flutter_version` is the one built with. A dependency never gets an older release than it asks for, so if one asks for a newer release than your pin, the build fails and names it: raise your pin, or set `allow_upgrade_by_dependencies = True` on your `flutter.toolchain` to build with the highest version any module asks for. Without a root pin, the highest version asked for is used. `flutter_pub.from_lock` reads your `pubspec.lock` and creates a repository, here named `deps`, with one target per package: `@deps//:flutter`, `@deps//:flutter_test`, `@deps//:collection`, and so on. See [Pub packages](#pub-packages). The two are separate extensions so that a lock `flutter_pub` refuses leaves the toolchain working, and with it the command that fixes the lock.

Some platforms need one more repository from the `flutter` extension. Add it to `use_repo(flutter, ...)` when you build for that platform:

| Platform | Add to `use_repo` |
|---|---|
| macOS | `flutter_macos_engine` |
| iOS | `flutter_ios_engine` |
| Web | `flutter_web_sdk` |

Android needs none: the engine of each ABI is rules_flutter's own, so a workspace names no Android engine repository.

The macOS and iOS engine repositories name the engine of the build mode directly, for a rule of your own that links the engine: `@flutter_macos_engine//:engine_library` and `@flutter_ios_engine//:Flutter_xcframework` are the debug engine under `-c dbg`, the profile engine under `-c opt --@rules_flutter//flutter:profile`, and the release engine under any other `-c opt`. To pin one engine whatever the mode, use `engine_debug_library`, `engine_profile_library` or `engine_release_library` on macOS (the Linux and Windows engines of the SDK repositories are named the same way), and `Flutter_xcframework_debug`, `Flutter_xcframework_profile` or `Flutter_xcframework_release` on iOS.

Static analysis needs nothing extra. rules_dart's analysis resolves `dart:ui` in a `flutter_library`, `flutter_plugin`, `flutter_test`, `flutter_application` or `flutter_application_variant` through the `sky_engine` package, which those rules add to the analyzer's closure themselves. Their compiled output does not change.

**Analysis and lints.** Static analysis is rules_dart's `dart_analyze` aspect, which `.bazelrc` turns on for `bazel test`; nothing runs without it. A lint set such as `flutter_lints` reaches the analyzer through a `dart_analysis_options` target, not through `deps`:

```starlark
# BUILD.bazel, beside analysis_options.yaml (`include: package:flutter_lints/flutter.yaml`)
load("@rules_dart//dart:defs.bzl", "dart_analysis_config", "dart_analysis_options")

dart_analysis_options(
    name = "options",
    src = "analysis_options.yaml",
    deps = ["@deps//:flutter_lints"],  # the package its `include:` names
)

dart_analysis_config(
    name = "analysis_config",
    options = [":options"],
)
```

```
# .bazelrc
test --aspects=@rules_dart//dart:analyze.bzl%dart_analyze
test --output_groups=+dart_analyze
common --@rules_dart//dart:analysis_config=//:analysis_config
```

`bazel test //...` then fails on any analyzer finding. [`e2e/android_example`](e2e/android_example/BUILD.bazel) is set up this way.

Each target is checked over its own files: a library's sources; a `flutter_test`'s, `flutter_application`'s or variant's `main` and `srcs`, whether or not they are under `lib/`; and, for an iOS, macOS, Linux, Windows or web app and an integration test, those of the program it runs. An Android app (rules_android's `android_binary`) passes on nothing, so check its program through the `flutter_application`. A `manual` target is not checked by `//...`; name it in a `dart_analysis_test(targets = [...])`.

### .bazelrc

Two settings are required. Paste them into your project's `.bazelrc`:

```bazelrc
# rules_flutter's Java dependencies (rules_jvm_external 7+, rules_android 0.7.2+)
# ship tool jars compiled for Java 21+. Bazel's default tool JDK is older.
common --tool_java_language_version=25
common --tool_java_runtime_version=remotejdk_25

# Windows only: rules_python 2+ needs symlink support.
startup --windows_enable_symlinks
```

Without the Java settings you get `UnsupportedClassVersionError` when an action runs, or `could not locate class file for java.lang.Record` when one compiles.

An Android app needs one more, unless the machine has a JDK installed:

```bazelrc
# The Java runtime an Android build resolves for the app's platform.
common --java_runtime_version=remotejdk_25
```

Without it Bazel takes the local JDK, and on a machine with none every Android build fails during analysis with `Cannot find Java binary bin/java in .../local_jdk/nosystemjdk`.

One more is recommended:

```bazelrc
# Share identical work between configurations, where Bazel can sandbox.
common --enable_platform_specific_config
common:linux --experimental_output_paths=strip
common:macos --experimental_output_paths=strip
```

A Flutter build reaches the same work in several configurations: each Android ABI compiles the same release kernel and bundles the same assets, `-c dbg` and `-c fastbuild` run the same codegen, and platform transitions give one target several output directories. Bazel keys an action by its paths, so each configuration's copy normally runs again. With this flag, Bazel rewrites `bazel-out/<config>/bin` to `bazel-out/cfg/bin` in every action that declares it can run that way, and the copies after the first are cache hits. rules_flutter's actions all declare it. The rewrite needs a sandbox or remote execution, so actions with `local` or `no-sandbox` tags run as before. Windows has no sandbox, and there Bazel fails a path-mapped action (`requires sandboxing due to path mapping`) rather than run it unmapped, so leave the flag off on Windows. Outputs still land in their own configuration's directory, so nothing that reads `bazel-out` changes.

A debug build's kernel is the one action that does not share across configurations: it carries the path of its `flutter_assets/`, which is how `flutter_bazel` tells an app's configurations apart.

**Remote execution.** Everything above builds on the machine running Bazel. To send actions to execution platforms of more than one kind (a Linux remote worker beside your Mac, say), rules_flutter works with Bazel's automatic execution groups, under which each action runs where the toolchain it names is registered, not where every toolchain its rule uses is:

```bazelrc
common --incompatible_auto_exec_groups

# Start py_binary tools with their hermetic interpreter, not python3 from
# PATH, which a remote worker does not have.
common --@@rules_python+//python/config_settings:bootstrap_impl=script
```

rules_flutter's actions land the same with the flag on or off: `gen_snapshot` for iOS and macOS, Xcode tools and signing run on a Mac; kernel compiles, asset and shader bundling and web compiles run on any host with the Flutter SDK; stripping the Android engine runs on the machine running Bazel, where its NDK is. An Android app needs fixes to rulesets it builds with, because rules_android 0.8.1, protobuf and rules_go have actions the flag rejects or places on the wrong host. [`e2e/android_example`](e2e/android_example/MODULE.bazel) is set up this way: copy its `single_version_override` patches for rules_android, protobuf and rules_go into your own `MODULE.bazel`. The downloaded NDK of the [Android](#android) setup declares which host each of its toolchains runs on; an installed one (rules_android_ndk 0.1.5, `ANDROID_NDK_HOME`) has toolchains that match any execution platform, so a remote worker would be sent this machine's clang. Build with the downloaded NDK when actions run remotely. Of those, `rules_android_no_initial_heap.patch` is not about remote execution: every Android build on a Windows host needs it (see **Building on Windows** under [Android](#android)).

### Your first app

Start from a project made with `flutter create`. It has `lib/main.dart`, a `pubspec.yaml`, and one folder per platform. rules_flutter reads those files as they are. You add a `BUILD.bazel`:

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    assets = glob(["assets/**"]),
    deps = [
        "@deps//:flutter",
        "@rules_flutter//flutter:material_icons",
    ],
)

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.my_app",
)
```

`flutter_application` compiles the Dart code and bundles the assets. Each platform then has a macro, like `flutter_macos_app`, that wraps it in a runnable app. Two attributes deserve a note:

- `dart_package_metadata` is the Bazel stand-in for `pubspec.yaml`: it states the package's facts once (its name, its language version, its licence), and every target of the package names it with `package`. A package has one, as it has one `pubspec.yaml`: it is always named `pubspec-metadata`, in the BUILD file at the package root (not one under `lib/`), and rules_dart refuses any other name or place. Its `package_name` must match the `name:` field in `pubspec.yaml`. Hot reload and code generation both rely on it. Where one program of the package needs a different native library than the package declares, its own `code_assets` replaces it (see [Choosing the library that serves an asset id](#choosing-the-library-that-serves-an-asset-id)); a second declaration is never the way.
- `@rules_flutter//flutter:material_icons` bundles the Material icon font. Any app that uses Material widgets needs it in `deps`.

Build it, or run it with hot reload:

```sh
bazel build //:my_app_macos
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

The second command is long. [Shorter commands with bazel_env](#shorter-commands-with-bazel_env) turns it into `fl run -t //:my_app_macos -d macos`.

### Build modes

Bazel's compilation mode flag selects how the Dart is compiled:

| Flag | Mode | Dart compilation | Use it for |
|---|---|---|---|
| `-c dbg` | Debug | Kernel `.dill`, run by the JIT | Development, hot reload |
| none (fastbuild) | Release | AOT native code | CI, tests |
| `-c opt` | Release | AOT native code, stripped | Production |
| `-c opt --@rules_flutter//flutter:profile` | Profile | AOT native code, stripped, with the Dart VM service | Measuring performance with DevTools |

Note that a plain `bazel build` is a release build, not a debug one. That matters for [permissions](#release-builds-and-permissions).

On iOS and macOS a release or profile build strips `App.framework/App` of its local symbols, as `flutter build ios` and `flutter build macos` do, and keeps them in a dSYM. The dSYM has the binary's UUID, so a crash reporter symbolicates the shipped app with it. It is in the `dsyms` output group of the app target: `bazel build //:app --output_groups=+dsyms`. `extra_gen_snapshot_options = ["--no-strip"]` keeps the local symbols in the binary, as it does for `flutter build`; the dSYM is still made. Keep it with each release. A dSYM of an `obfuscate = True` app holds the unobfuscated Dart names (`gen_snapshot` warns of it), so keep it out of the shipped app. `flutter_aot_snapshot` on an Apple platform is not stripped, and its object is in the `macho_object` output group.

Profile mode is `flutter run --profile`: release-speed code that still serves the Dart VM service, so DevTools can record timelines and CPU profiles. It has no hot reload. Profile uses its own engine and gen_snapshot on every platform, downloaded the first time a profile build needs them, because the engine refuses a snapshot compiled for a different mode. The flag needs `-c opt`, and the build fails if it is set with any other `-c`. Like upstream Flutter, there is no profile mode for the iOS simulator: build profile for a physical device. A `.bazelrc` config saves typing:

```
build:profile -c opt --@rules_flutter//flutter:profile
```

To check a profile build from a test without those flags on the command line, wrap the app in [`flutter_profile_build`](#flutter_profile_build).

## Dependencies

### Pub packages

`flutter_pub.from_lock` turns `pubspec.lock` into Bazel targets. Every package in the lock gets a target in the hub repository (a package you map with `resolve` is your target, see "Packages in your workspace" below): `@deps//:collection`, `@deps//:url_launcher`, `@deps//:flutter_test`. List them in `deps` like any other target:

```starlark
flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:collection",
        "@deps//:url_launcher",
        "@rules_flutter//flutter:material_icons",
    ],
)
```

Plugins need no special treatment. A pub package that is a Flutter plugin arrives as a plugin target, and the platform macros register it and build its native code. On Android, `flutter_android_app` links the Kotlin and Java of the plugins your application depends on, and only those: a plugin the lock lists and the application does not use adds no code, no manifest entries and no Maven requirements to the APK. A plugin written in your workspace joins the same way when its `flutter_plugin` lists the Android library in `exports`, under `select({"@platforms//os:android": [":lib"], "//conditions:default": []})`, so that other platforms never load it.

The Flutter SDK packages a lock lists with `source: sdk` build too. `package:flutter` has its own rule; `flutter_test`, `integration_test`, `flutter_driver` and the rest are built from `packages/<name>` of the Flutter source the toolchain pins (the tarball every SDK package shares, checked against the digest recorded for the version), as a hosted package is built from its archive. Name whichever the lock lists, as `@deps//:integration_test`: the list is the lock's, not a list the rules know. A package the pinned release does not have fails the fetch, naming it and the command that re-resolves the lock. An SDK package's Android library links as any plugin's does, into the apps that depend on the package: `integration_test`'s needs `androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core` and `com.google.guava:guava` in your `maven.install`, and an app that does not depend on it does not.

#### Git packages

A dependency with `git:` in `pubspec.yaml` is listed in `pubspec.lock` with `source: git`, and it builds like a hosted one: a plain package, a package with assets or a plugin, as its own `pubspec.yaml` says. The hub fetches the commit the lock records (`resolved-ref`) and lays out the package's directory of the repository (`path:`, the repository root by default) as `dart pub get` does, so a package in a monorepo is only its own directory. Run `bazel run @rules_flutter//flutter/pub -- get` after changing the dependency, and commit the lock: it is what pins the commit.

- A `resolved-ref` that is not a full commit id is refused when Bazel reads the lock, naming the lock and the package. Run `pub get` to have pub write the commit it resolved.
- The fetch uses the `git` on your machine and its configuration, so credential helpers, `url.<base>.insteadOf` mirrors and proxies work as they do for `dart pub get`. Writing the files uses none of it: attributes in the repository apply, a host's line-ending or filter settings do not, so the same commit is the same files everywhere. A `git` older than 2.14 is refused.
- A git package may instead be mapped to a target of your own with `resolve` (see below), and is then never fetched.

#### Pub packages' assets

A package's `flutter: assets:` are bundled at `packages/<package>/<path>`, as `flutter build` bundles them. A listed image ships its resolution variants from the `<number>x/` directories beside it. A listed directory (a trailing slash) ships the files directly in it, and nothing from the directories below it. An entry with `platforms:` ships only in builds for those platforms, and an entry with `flavors:` ships only in a build of one of those flavors (an application's `flavor`), and in no build without one. Two entries that give one file different flavors fail the build, as `flutter build` does. A package's `flutter: shaders:` entries follow the same rules. A name with a space or a non-ASCII character is stored percent-encoded, the form the engine asks for, and listed in the manifest as written.

#### Packages that depend on each other

Pub allows packages to depend on each other in a cycle (`dio` and `dio_web_adapter` import each other); Bazel does not. Such packages are built as one library, so `@deps//:dio` and `@deps//:dio_web_adapter` both name it. Each package keeps its own name, language version, assets and plugin, so the app gets what `flutter build` would give it. A cycle is built this way only where it is declared:

```starlark
flutter_pub.cycle(packages = ["ping", "pong"])
```

- An undeclared cycle fails when something first builds one of its packages, naming every package in it and the `flutter_pub.cycle()` to add.
- A declaration must name exactly one cycle at the versions the build uses. One that names packages in no cycle (a new release dropped the dependency, say), or only part of a cycle, fails the same way, so a declaration cannot outlive its cycle. One naming a package the build does not build from a lock (`package:flutter`, a package mapped with `resolve`) fails when the module is read.
- Cycles apply to the whole build, as versions do, and the root module decides. Declarations by a module the root depends on apply where they name exactly a cycle and do nothing otherwise, since that module cannot fix what the root's versions made of them.
- rules_dart declares the cycles of well-known packages itself (`curated_cycles()` in `@rules_dart//dart/ext:registry.bzl`; today `dio` and `dio_web_adapter`), so a lock with them needs no declaration. These apply the same way, and do nothing where the packages are not that cycle.
- A package built from a plugin overlay cannot be in a cycle, and the build says so.

#### Packages in your workspace (`path:` dependencies, forks)

A `path:` dependency in `pubspec.yaml` is a package whose files are in your repository, and `pubspec.lock` lists it with `source: path`. Usually you build those files with a target of your own, and `resolve` tells the hub which one builds which package:

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//apps/greeter:pubspec.lock",
    resolve = {
        "greeting": "//packages/greeting",              # //packages/greeting:greeting
        "tagline": "//packages/tagline:tagline_lib",
    },
)
```

- The target is a `flutter_library`, a `flutter_plugin` or a `dart_library`. Its name is free; the `package_name` of its `dart_package_metadata` must be the pub package's name, or analysis fails naming the target, the key and the name it declares. For a package with assets, fonts or shaders that is also what bundles them at `packages/<package>/<path>`, as `flutter build` does. The target must be `//visibility:public`, because the hub's repository forwards to it.
- Every `path` package of the lock must be named in exactly one of `resolve`, `build_from_pubspec` and `ignored` (below). Usually it is mapped to the target in the Bazel package at the path (`../../packages/greeting` from `apps/greeter` is `//packages/greeting`), but where the path points is pub's concern only: a package pub reads from a sibling checkout can be mapped to a target of the module Bazel takes it from (`"ui_kit": "@ui_kit"`). A `path` package named nowhere fails as soon as Bazel reads the lock, naming the lock and the package, with the lines to add.
- A hosted, git or `sdk` package may be mapped as well, from any repository, to replace it for the whole graph with a fork or a patched copy. The hub's `@deps//:<package>` is then your target, a hosted package that depends on it gets it too, and the locked package is never fetched. The lock's version is not checked against your target. Naming a package the lock does not list is an error.
- Depend on a mapped package as `@deps//:greeting`, or by its label.
- If your target depends back on a hosted package that depends on it, the build fails with Bazel's cycle error: pub allows the cycle, and Bazel does not.
- One lock serves one repository: the package's `BUILD.bazel` names one hub's labels (`@deps//:intl`), so two apps with two locks cannot share a package this way. Use one lock for the monorepo, resolved from a pub workspace or from one app.
- The members of a pub workspace (`workspace:` in the root `pubspec.yaml`) are not in the lock. Depend on them by label.
- A lock below the repository root is resolved with `bazel run @rules_flutter//flutter/pub -- get --directory=apps/greeter`.

A `path` package with no Bazel build, such as the `<plugin>_android` package of a federated plugin, which is only Kotlin and a Gradle build, is named in `build_from_pubspec`. rules_flutter builds its directory exactly as it builds a package from pub.dev or git, and as `flutter build` builds every `path` package: its Dart library, assets, fonts and shaders, and its Android, iOS, macOS, Linux and Windows plugin code, with the plugin class, namespace, manifest, Maven dependencies and ProGuard files read from its pubspec and Gradle files. Depend on it as `@deps//:<package>`.

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    build_from_pubspec = ["keyboard_android"],
    ignored = {"release_tool": "run with `dart run` outside Bazel"},
)
```

- The directory is the lock's path, relative to the lock's directory, and may be outside the repository. Bazel reads `pubspec.yaml`, `lib/`, `hook/`, the license, the platform directories and the directories the pubspec lists assets, fonts and shaders from, and sees edits to them. Tool output (`build/`, `.dart_tool/`, `android/.gradle/`, `android/build/`) is left out and does not make Bazel fetch the package again.
- A directory that holds a `BUILD`, `BUILD.bazel`, `MODULE.bazel`, `REPO.bazel` or `WORKSPACE` file is refused: it has a Bazel build, so map it with `resolve`. So is a package whose code is generated, or built by Bazel another way (the Rust behind a flutter_rust_bridge `rust_builder`): its pubspec does not say how to build it, so map it to the target that does.

A `path` package that no Bazel build may contain, such as a tool run with `dart run` outside Bazel, is named in `ignored` with the reason. The lock loads, and a target that depends on `@deps//:<package>` fails at analysis with ``package `<package>` (in <lock>) is ignored: <reason>``.

#### Plugins' Maven dependencies

A plugin's `android/build.gradle(.kts)` declares the Maven artifacts its Kotlin or Java compiles against, such as `androidx.datastore:datastore` for `shared_preferences_android`. Those come from the same place as the embedding's androidx libraries: `@rules_flutter_maven`, rules_flutter's own rules_jvm_external repository, which your root `MODULE.bazel` extends with a `maven.install(name = "rules_flutter_maven")` of its own (see **Maven dependencies** under [Android](#android)). That is one resolution for the whole app, so there is one version of each artifact, and when two plugins want different versions the highest wins, as it does under Gradle. An app whose plugins declare no Maven artifacts needs no install: rules_flutter's lock covers it.

rules_flutter reads these Gradle forms:

- `implementation`, `api` and `compile` (on the compile and runtime classpath), `compileOnly` and `provided` (compile only), and `runtimeOnly`. Test, `androidTest`, lint and `classpath` lines are ignored.
- A single string literal `"group:artifact:version"`, in single or double quotes, with or without parentheses. A `:classifier` or `@packaging` suffix is dropped.
- A version written `$x` or `${x}` takes its value from a string defined in the same file with `def x = "..."`, `val x = "..."`, `var x = "..."`, `ext.x = "..."` or `ext["x"] = "..."`. A variable it cannot find, or a dynamic version (`1.+`, `[1.0,2.0)`, `latest.release`), only checks that the artifact is present, whatever its version.
- `org.jetbrains.kotlin:kotlin-stdlib*` and `io.flutter:*` are skipped: the Kotlin rules and the engine provide them.
- The declaration sits directly in the script's `dependencies { }` block (or one inside `android { }`). A declaration inside an `if`, an `afterEvaluate` or any other block, which Gradle may or may not run, is linked when `@rules_flutter_maven` has the artifact and is not required.

When an artifact is missing from the install, or resolves lower than a plugin declares, the Android build fails when it links the plugin, and one message lists every such artifact for the plugins that app links, with the packages that declare it. A plugin the app does not depend on is not checked:

```
"androidx.datastore:datastore:1.1.7",  # declared by package:shared_preferences_android 2.4.28; missing
"androidx.core:core:1.17.0",  # declared by package:url_launcher_android 6.3.29; resolves 1.0.0
```

Add those lines to `artifacts = [...]` and re-pin the install's lock file:

```sh
REPIN=1 bazel run @rules_flutter_maven//:pin
```

To get the block for an app before building it, `bazel run //:my_app_maven_artifacts` (`<name>_maven_artifacts` for a `flutter_android_app` named `my_app`; `flutter_android_maven_artifacts` declares the same for a hand-wired app) prints the lines for the plugins that app depends on, and no others, marking the entries that are missing or too low. It works while the build is failing for lack of them, which is when to run it. `bazel run @<hub>//android:maven_artifacts`, for any hub, prints the block for every plugin of the build instead: use it to seed `maven.install` before any app exists, or for a workspace with several apps that share one install. Only Android builds read any of this; a web or desktop build never fetches it.

Gradle also aligns libraries that are published together. androidx `activity` 1.9.0 declares, in its Gradle module metadata (the `.module` file beside its POM), that `activity-ktx` must be 1.9.0 too, because the Kotlin extensions moved from `activity-ktx` into `activity`. Coursier reads only POMs, so an install whose `preference` 1.2.1 asks for `activity-ktx` 1.5.1 keeps it beside `activity` 1.9.0, and the two jars define the same classes differently. Both `maven_artifacts` programs therefore also read the `.module` file of every artifact the install resolves, from the install's repositories (so they need network access, as the pin does), and print a line for each artifact Gradle would raise. To run one without the network, as a test does, record that metadata once with `bazel run //:my_app_maven_artifacts -- --record=<file>` and read it back with `-- --metadata=<file>`, which fails naming any artifact the file lacks. Each line it prints for an artifact to raise looks like this:

```
"androidx.activity:activity-ktx:1.9.0",  # aligned with androidx.activity:activity 1.9.0; resolves 1.5.1
```

Building a `flutter_android_app` checks the result: when two jars it links define a class with different bytes, the build fails and names both, with their Maven coordinates. The app's deploy jar would keep whichever copy comes first, a mix of two versions of one library. Resource classes (`R`, `R$string`) are not compared, since every Android library carries its own and `android_binary` replaces them with the app's. Two jars that differ can also both be fine, as when either copy of an interface works or an app shadows a library's class on purpose: build with `--@rules_flutter//flutter:allow_duplicate_classes` to let them through (the Android Gradle plugin's `android.enableDuplicateClassesCheck=false`), and the deploy jar keeps the first copy. The build also fails when one Maven library (`group:artifact`) reaches the app from two rules_jvm_external repositories, `@rules_flutter_maven` and another, since each resolves its versions on its own: the message names both targets. Depend on the `@rules_flutter_maven` one; for a target of another module's repository, which you do not edit, send that repository's copy to ours from your root module with `maven.override(name = "<its repository>", coordinates = "<group:artifact>", target = "@rules_flutter_maven//:<target>")`.

Coursier, which resolves the install, is stricter than Gradle about exact version ranges. For example, `androidx.preference:preference:1.2.1`, which `shared_preferences_android` needs, depends on `androidx.fragment:fragment` as `[1.3.6]`, an exact version, while other artifacts want a higher one. Gradle lets the higher version win; Coursier alone reports a conflict. rules_flutter's own `maven.install` passes Coursier `--reconciliation *:*:relaxed` through `additional_coursier_options`, which makes it pick the highest version too. rules_jvm_external concatenates those options across every module that declares an install of the name, so your `maven.install(name = "rules_flutter_maven")` inherits them and needs no `force_version` entries for such ranges. Do not set `resolver = "gradle"` or `"maven"` to get this: the Gradle resolver selects the JVM or desktop variant of Kotlin Multiplatform libraries (for example `androidx.lifecycle:lifecycle-runtime-desktop`) in place of the Android one, and the Maven resolver reports the same hard-range conflict.

Building an app checks the declarations rules_flutter reads, and fails naming any artifact `@rules_flutter_maven` lacks or has too low. Everything else in the plugins it links is a warning, naming the plugin, its Gradle file and each line, since a reader of Gradle files that is not Gradle can be wrong about it: a declaration inside a block, and a dependency written any other way (a version catalog entry such as `libs.foo`, `project(...)`, `platform(...)`, `files(...)`, Groovy map notation, a trailing `{ exclude ... }` block, `kapt`, `ksp`, `annotationProcessor`, `coreLibraryDesugaring`, a `debugImplementation`-style variant configuration, or an `apply from:` script), which the plugin's library does not link. If the plugin's Android code then fails to compile for want of one, add the artifact to your `maven.install(name = "rules_flutter_maven")` and state it for that plugin in your root `MODULE.bazel`:

```starlark
flutter_pub.annotation(
    package = "some_plugin",
    android_deps = ["@rules_flutter_maven//:androidx_browser_browser"],
)
```

`flutter_pub.annotation` adds each label to the generated Android library of that one package, as `crate.annotation` does for a Rust crate in rules_rust. The labels count as if the plugin's Gradle build had declared them: the app's build fails, naming it, when `@rules_flutter_maven` does not resolve one, `<app>_maven_artifacts` lists it as declared by the plugin, and the app is checked for a second copy of the library like any other. A plugin you annotate no longer triggers the warning for its unread lines, since you have stated its dependencies. Only the root module may use the tag, once per package, and it fails the build when no lock lists the package, or when the package is not a plugin with Android sources that rules_flutter builds the library of (one with an overlay lists its own dependencies in its `android/BUILD.bazel.tpl`). A plugin that needs more than dependencies can have an overlay instead: a `BUILD.bazel.tpl` for the package and an `android/BUILD.bazel.tpl` that declares its Android library and the `@rules_flutter_maven` labels it needs. The `android/` template is used only beside the top-level one, and the top-level template's `flutter_plugin` must list that library under `exports`, as above, for an app to link it.

Permissions a plugin declares in its own manifest, such as `record_android`'s `RECORD_AUDIO`, reach the app's manifest as they do under Gradle. You don't need `--merge_android_manifest_permissions`.

### System libraries of Linux and Windows plugins

A plugin's C++ sources are compiled into your Linux or Windows app, so the app must be linked with the system libraries they call. rules_flutter reads them from the plugin's own `windows/CMakeLists.txt` or `linux/CMakeLists.txt`: the `target_link_libraries` calls that name the plugin's library. `url_launcher_windows` links `shlwapi.lib` that way, and so its Windows app links `shlwapi.lib`.

- `flutter` and `flutter_wrapper_plugin` (Windows), `flutter` and `PkgConfig::GTK` (Linux) are what the app links already.
- A plain library name (`shlwapi`, `dwmapi.lib`, `m`) becomes a linker flag.
- A list variable (`${wmf_libs}`) is read when the file sets it once, outside any block, to literal values before the call: `set(wmf_libs mf.lib mfplat.lib)`. Its values are read as above.
- Anything else needs CMake to evaluate it: any other variable, a generator expression, an imported target such as `PkgConfig::LIBSECRET`, a target the plugin defines or fetches, a path, or a call inside an `if()` block.

For a plugin with something of the last kind, the Windows or Linux app fails when it is built, listing each line and its package. Other platforms are unaffected. Supply a plugin overlay with `flutter_pub.plugin_overlays`: a `BUILD.bazel.tpl` for the package that declares its `flutter_windows_plugin_library` or `flutter_linux_plugin_library` with the flags its sources need in `linkopts`.

### Plugins whose own build makes a native library

Some plugins make a library with their platform's build system rather than from sources rules_flutter compiles. rules_flutter does not run Gradle, CocoaPods or CMake, so it cannot make that library. It recognises these cases from the plugin's own files:

- Gradle's `externalNativeBuild` (CMake or ndk-build) in `android/build.gradle(.kts)`, as `package:jni` uses.
- cargokit, which `flutter_rust_bridge` plugins use to build a Rust crate with cargo: `apply from: ".../cargokit/gradle/plugin.gradle"` in the Gradle script, a podspec script phase running `cargokit/build_pod.sh`, or `apply_cargokit()` in a `CMakeLists.txt`.
- Any other CocoaPods script phase (`s.script_phase`) in the plugin's podspec, for a platform without a `Package.swift`, which Flutter builds instead (see below).
- A `CMakeLists.txt` that sets `<plugin>_bundled_libraries`, Flutter's way of shipping a library the plugin's CMake build makes or downloads.
- `ffiPlugin: true` for the platform in the pubspec, which tells Flutter to build the plugin's native sources into a library that Dart opens, unless the platform is iOS or macOS and the plugin has a `Package.swift` (see below).

An app built without the library would fail at run time when the plugin loads it, so the build for that platform fails instead, naming the package, the platform and the mechanism. Builds for the plugin's other platforms are unaffected. To build the app, build the library with Bazel (a `rust_shared_library` of `rules_rust` for a Rust crate, a `cc_shared_library` for C or C++) and give the package a target that lists it in `native_deps`, in either of two ways:

- A plugin overlay (`flutter_pub.plugin_overlays`): a `BUILD.bazel.tpl` for the package whose `flutter_plugin` lists the library. `@rules_flutter//ext/jni` does this for `package:jni`.
- A `flutter_plugin` of your own, which `flutter_pub.from_lock(resolve = {"<package>": "//your:target"})` puts in place of the package (see "Packages in your workspace").

### Apple plugins built from their Package.swift

An Apple plugin whose iOS or macOS side is a Swift package (`ios/<plugin>/Package.swift`, or `darwin/<plugin>/Package.swift` with `sharedDarwinSource`) is built as its manifest says, as `flutter build` does with Swift Package Manager. rules_flutter reads the manifest with Xcode's `swift package dump-package` and compiles the targets of the plugin's library product (`flutter-qjs-next` for `flutter_qjs_next`) and the targets of the package they depend on on that platform, each a module of its own, as `video_player_avfoundation`'s four targets are. For each target:

- its sources, as the target's `path`, `sources` and `exclude` give them, Swift, Objective-C, C and C++ alike;
- its public headers (`publicHeadersPath`) and header search paths;
- its resources (`.process` and `.copy`), in the bundle SwiftPM makes for them (`<package>_<target>.bundle`), which `Bundle.module` (Swift) and `SWIFTPM_MODULE_BUNDLE` (Objective-C) find;
- its Swift language mode: the target's `swiftLanguageMode`, else the package's `swiftLanguageModes`, else Swift 6 for `swift-tools-version: 6.0` and Swift 5 before;
- its settings: `.define` and `.unsafeFlags` in `cSettings`, `cxxSettings` and `swiftSettings`, `linkedFramework`, `linkedLibrary` and `.unsafeFlags` in `linkerSettings`, Swift's upcoming and experimental features, and the package's C and C++ language standards. A setting for `.when(configuration: .debug)` applies to builds other than `-c opt`, one for `.release` to `-c opt` (Flutter's profile and release modes), and one for other platforms to none.

As in `flutter build`, a plugin with a `Package.swift` is built from it whatever its podspec does (a script phase included), and an FFI plugin (`ffiPlugin: true`) with one is linked into the app, where Dart finds its symbols with `DynamicLibrary.process()`.

Only an iOS or macOS build reads the manifests, and it needs Xcode for it, as any Apple build does. Other platforms, and other hosts, never evaluate a manifest.

#### Swift packages a plugin depends on

A plugin's package can depend on other Swift packages, as the Firebase plugins depend on `firebase-ios-sdk`:

```swift
.package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "13.1.1"),
```

`flutter build` resolves those through Xcode and records the versions in a `Package.resolved`. rules_flutter builds them from such a file, with [rules_swift_package_manager](https://github.com/cgrindel/rules_swift_package_manager). Write it, and commit it:

```sh
bazel run @deps//swift:resolve      # `deps` being your flutter_pub.from_lock's name
```

It resolves every Apple plugin's package of the lock, for iOS and macOS, as Flutter's generated plugin package does, and writes `Package.resolved` beside `pubspec.lock`. Name it in the tag:

```starlark
flutter_pub.from_lock(
    name = "deps",
    lock = "//:pubspec.lock",
    swift_package_resolved = "//:Package.resolved",
)
```

Run it again after a change to `pubspec.lock` that changes a plugin's Swift dependencies. An iOS or macOS app that links a plugin whose package depends on a package the file does not pin fails at analysis, naming the package and the command. Each pinned package is fetched only when an iOS or macOS build needs it.

A C-family source is compiled with Clang's module autolinking on, as Xcode compiles it, so an SDK framework the plugin imports and does not name (`permission_handler_apple`'s `CoreTelephony`) is linked into the app.

Some manifests rules_flutter cannot honour this way, and an iOS or macOS app that links such a plugin fails at analysis, saying why: a library product of several targets none of which is named after the plugin (Flutter imports the module of that name), a binary target, or a setting rules_flutter does not apply. Other platforms are unaffected. Give such a plugin an overlay (`flutter_pub.plugin_overlays`) whose `flutter_apple_plugin_library` builds it.

#### Plugins whose Package.swift reads the app

Some manifests compute their defines from what surrounds the build. `permission_handler_apple` finds the app it is built for and turns on a permission's code only when the app's `Info.plist` has its usage description: `NSCameraUsageDescription` gives `PERMISSION_CAMERA=1`. `audio_session` reads the environment variable `AUDIO_SESSION_MICROPHONE`, and `geolocator_apple` reads `BYPASS_PERMISSION_LOCATION_ALWAYS`. Under `flutter build`, Xcode evaluates such a manifest once per app, from the app's folder, in the shell's environment.

rules_flutter does the same for each app, during the build. A manifest that imports more than `PackageDescription`, or reads its `Context`, and sets `.define`s is evaluated again for each iOS or macOS app that links the plugin. It sees a stand-in of the app's folder, as it would under Xcode: a `pubspec.yaml`, and in `ios/` (or `macos/`) an Xcode project whose `INFOPLIST_FILE` is the Info.plist the app is built from (its `info_plist`, or `ios/Runner/Info.plist`). Its environment is the app's `swift_package_environment`, and nothing else from your shell:

```starlark
flutter_ios_app(
    name = "app",
    application = ":app_flutter",
    bundle_id = "com.example.app",
    # What audio_session's README says to export before `flutter build`.
    swift_package_environment = {"AUDIO_SESSION_MICROPHONE": "1"},
)
```

`flutter_macos_app` takes the same attribute. Set what the plugin's README says to export: the dict is the environment of every such manifest of the app, as the shell is under Xcode, so the manifest still decides what each variable does. An app whose Info.plist explains the camera gets permission_handler's camera code and no other permission's, with no attribute at all.

The defines are the only part of such a manifest that may depend on the app. Its sources, header search paths, dependencies and other settings are read once, when the plugin is fetched, and an evaluation for an app that gives anything else differently fails the build, naming the difference.

Each such plugin is compiled once per distinct pair of Info.plist and environment: two apps with the same plist target and the same environment share it, and a third gets its own. A separate build of a plugin also gets its own copy of the C and Swift tools it is compiled with, built once and then cached. A workspace with several apps can avoid that copy with `--incompatible_exclude_starlark_flags_from_exec_config` in its `.bazelrc`; Bazel 9.3 accepts the flag, though `bazel help` does not list it yet.

What the stand-in folder leaves out is the rest of your app's tree, so a manifest that reads other files of the app does not find them. permission_handler's `permission_handler.yaml` flavors are one: in Bazel, a flavor is an app target of its own with its own Info.plist, which is what that file emulates.

### Regenerating pubspec.lock

Bazel reads `pubspec.lock` and never writes it. To regenerate it, use the Flutter toolchain the rules pin rather than a Flutter installed on your machine:

```sh
bazel run @rules_flutter//flutter/pub -- get       # after editing pubspec.yaml
bazel run @rules_flutter//flutter/pub -- upgrade
bazel run @rules_flutter//flutter/pub -- add qr
```

Arguments pass through to `dart pub` unchanged, and the command runs at your workspace root, so the lock lands where `flutter_pub.from_lock` reads it.

The version of Flutter that resolves the lock matters, and a mismatch is easy to miss. Pub treats the running Dart and Flutter versions as constraints, so an older installation quietly picks older packages, and the lock it writes is still valid. Nothing downstream can tell the difference.

The fetched toolchain contains engine artifacts and a Dart SDK but no `bin/flutter`, so this target runs `dart pub` with `FLUTTER_ROOT` pointed at a tree assembled from the same Flutter release. That tree is fetched the first time you run the target. Because it is `dart pub` rather than `flutter pub`, it writes `pubspec.lock` and `.dart_tool/package_config.json` and does not write `.flutter-plugins-dependencies`. rules_flutter generates plugin registrants from the build graph, so nothing needs that file.

A package below the workspace root, such as a `tools/*` package or an app of a monorepo, is resolved by the same target with pub's `--directory` flag. The path is relative to the workspace root, and the lock lands beside that package's `pubspec.yaml`:

```sh
bazel run @rules_flutter//flutter/pub -- get --directory tools/my_tool
```

### Several locks in one build

Every package is one repository for the whole build, however many `flutter_pub.from_lock` tags list it: a hub (`@deps//:flutter`) is the set of aliases its own lock names. A build has one version of each package. Each lock's hosted entry is a request for at least that version, in whichever module the lock is, and the highest request is built, as Bazel's minimal version selection picks the highest version any module asks for. rules_flutter and rules_dart share this policy.

Raising another module's lock says nothing: that is what a minimum means. When a lock of the root module is raised, the build prints a warning, as Bazel's `--check_direct_dependencies` does for a `bazel_dep`:

```text
Package "meta" is built at 1.17.0, newer than the root module asks for:
  - 1.16.0, from the lock `//app:pubspec.lock`
Raised by:
  - 1.17.0, from the lock `//:pubspec.lock` in module `some_module`
Each request is a minimum and the highest wins. Raise the root's to 1.17.0:
  bazel run @rules_flutter//flutter/pub -- upgrade --directory=app meta
or set `flutter_pub.settings(check_direct_dependencies = "off")` in the root module to stop this check.
```

Run the command from the workspace root; it runs even while the extension fails. The root module sets how this is reported, once:

```starlark
flutter_pub.settings(check_direct_dependencies = "error")  # "off", "warning" (the default) or "error"
```

At `"error"` the message fails every build that uses a hub. The toolchain comes from the other extension, so the fix still runs. The locks must otherwise agree, at every level: a package from different sources, registries or digests, or git commits, or `build_from_pubspec` directories, always fails. `resolve` applies to the whole build. Only the root module may use `flutter_pub.settings` and `ignore_hooks`: another module's fails the build. rules_flutter's own tools are a lock of another module in your build, so a release that moves them ahead of your lock raises it, with the warning above.

### Packages with build hooks

Some pub packages compile native code through a Dart `hook/build.dart` (Dart Native Assets). Bazel does not run those hooks. Instead:

- **Curated replacements.** rules_dart keeps a registry of Bazel-native equivalents (`@rules_dart//dart/ext:registry.bzl`). Where one exists, such as `sqlite3`, `flutter_pub.from_lock` attaches it automatically. An app that depends on `drift` gets `libsqlite3` without naming it.
- **Overlays.** For a package with a hook and no curated entry, you can write a `BUILD.bazel.tpl` that reproduces what the hook builds. rules_flutter bundles overlays under `ext/`, and you can add your own with `flutter_pub.plugin_overlays(roots = [...])`. Authoring one is described in [docs/TESTING.md](docs/TESTING.md) under "Native Assets overlay authoring". An overlay is also a way to give a plugin Android dependencies rules_flutter does not read, but `flutter_pub.annotation(android_deps = ...)` says that in a few lines and keeps the generated library (see [Plugins' Maven dependencies](#plugins-maven-dependencies)).
- **Ignoring a hook.** If a package's native code is never reached in your app, say so in the root module: `flutter_pub.from_lock(ignore_hooks = ["<package>"])`.

A hook that nothing replaces is an error when `flutter_application` reaches it. The alternative would be a build that succeeds and then fails at runtime on an unresolved `@Native` symbol.

### Native code from Bazel

A Flutter app can depend on native code built by any Bazel rule that produces a shared library: `rules_cc`, `rules_rust`, and so on. List the library in `native_deps` and it is bundled beside the app, where `dart:ffi` can open it:

```starlark
cc_shared_library(
    name = "my_native_lib",
    deps = [":my_cc_lib"],
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    native_deps = [":my_native_lib"],
    deps = ["@deps//:flutter"],
)
```

If you would rather bind with `@Native(assetId: ...)` and let the Dart VM find the library, declare it as a code asset with rules_dart's `dart_code_asset` and name it in the `code_assets` of the package's `dart_package_metadata`, as a pub package's build hook would supply it. Every program that depends on the package then bundles the library under its file name, wrapped in a framework on iOS, and maps the id to it. `e2e/ffi_example` shows both styles side by side.

#### Choosing the library that serves an asset id

A package that owns an asset id supplies its library through the `code_assets` of its `dart_package_metadata`. An application or a `flutter_test` can serve the id from a different library by naming one in its own `code_assets`, which replaces whatever its `deps` supply under that id, as on rules_dart's `dart_binary` and `dart_test`. This is the place for a library that differs between programs of one package: the package has one declaration, so a second one stating other assets is refused. Several ids can name one library. That is how two bridges linked into one shared library run against one copy of it:

```starlark
cc_shared_library(
    name = "combined",
    deps = ["//bridge_a:native", "//bridge_b:native"],
)

dart_code_asset(name = "a_combined", asset_id = "package:a/a", shared_library = ":combined")
dart_code_asset(name = "b_combined", asset_id = "package:b/b", shared_library = ":combined")

flutter_application(
    name = "my_app",
    code_assets = [":a_combined", ":b_combined"],
    deps = ["//a", "//b", "@deps//:flutter"],
    # ...
)
```

The library is bundled once (one file, or one `.framework` on iOS) and every id's manifest entry names it, so the process loads one image of it: one runtime and one copy of its static state, whichever id a call goes through. Wrap each entry in a `flutter_native_library` to give each id the contract of its own bindings; the wrappers of one library may name a `hot_patch` between them, and if several do, it must be the same one, since one patch of the shared library serves every id.

#### Hot reload across a native rebuild

A running process cannot pick up a rebuilt native library; it keeps the one it already loaded. So when a native library goes stale under a hot reload, the dev tool has to decide whether the Dart it is about to inject still matches that library. Without more information it withholds the reload, and a pending native change blocks your Dart edits until you restart.

The build tells it which files each native library is built from, so a reload notices an edit to a `.c` or `.rs` file even in an app that runs no build of its own — the reload stats those files, and nothing more. Before that, such an app reported a reload as successful while it went on running the machine code it launched with.

You can tell it what the bindings were generated from, and then it can decide:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
)

flutter_application(
    name = "my_app",
    native_deps = [":bridge"],
    # ...
)
```

A library that reaches Dart as a code asset (a target providing rules_dart's `DartCodeAssetInfo`, loaded through `@Native`) is wrapped the same way. The wrapper is itself that code asset, so it goes where the bare asset would have gone: in the `code_assets` of the `dart_package_metadata` of the package that owns the asset id, whichever of `flutter_plugin`, `flutter_library` or `dart_library` its targets are.

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_code_asset",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
)

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_bridge_bindings",
    code_assets = [":bridge"],
)

dart_library(
    name = "my_bridge_bindings",
    srcs = ["lib/bindings.dart"],
    package = ":pubspec-metadata",
)
```

The build finds a code asset's target however the package that owns it is reached. A package rule that makes its asset with no target of its own leaves nothing to find, so hot reload could not tell when that library changes: a debug build of the application fails, naming the library. Declare the asset with a target of its own (a `dart_code_asset`, or a `flutter_native_library` wrapping one) and name it in the application's `code_assets`. Other builds bundle it as usual.

`binding_contract` is whatever file decides what may be called and how: a binding generator's interface description, or the C header a hand-written FFI binding follows. The dev tool compares the bytes of those files and nothing else, so what matters is that every change to the wire format shows up in them, and that changes which do not affect the wire do not.

With that declared, a reload has three outcomes:

| What changed | What the reload does |
|---|---|
| Nothing native | Ordinary reload. |
| The library's code, but not its contract | Delivers the edit and reports that the native code in the process is stale. |
| The contract | Withholds the edit. Restart to pick up the new library — unless the library declares a `hot_patch` builder, which is asked instead (below). |

#### Patching native code into a running app

A process cannot replace a library it has loaded, but it can load a second one and send calls there. If the toolchain that builds your library can build such a patch, and the library routes its calls so that a patch can take them over, a hot reload delivers a native edit into the running app the way it delivers a Dart edit: state kept, no relaunch. Name the target that builds patches as `hot_patch`:

```starlark
flutter_native_library(
    name = "bridge",
    library = "@my_bridge//bridge:bridge_shared",
    binding_contract = ["@my_bridge//bridge:codegen.ir"],
    hot_patch = "@my_bridge//bridge:bridge_hot_patch",
)
```

On each hot reload the dev tool checks the source files that target declares. When none moved, that is a content hash per file and nothing else. When one did, it builds the patch for the configuration the app is running in, puts it where the app can load it (signed with the app's own identity on an iOS device), has the app load it, and then applies the Dart half of the edit. A widget that shows a native result is rebuilt, so the new answer appears even when no Dart changed.

| What changed | What the reload does |
|---|---|
| A function body | Patches it into the running app. The reply names the library and what was patched. |
| The contract | Asks the patch builder, which is the half that holds both interfaces. A patch that carries the new surface — a bridged function added, say — is delivered like any other. |
| Anything the builder says a patch cannot carry (a struct's layout, say) | Withholds the edit and says why, in the builder's words. Restart to pick it up. |
| An edit undone after it was patched | Sends calls back to the code the app launched with. |

A restart (`R`) is still the reset: if any patch is live, or the rebuilt bundle differs from the launched one, it relaunches the app.

What a `hot_patch` target builds, and what the library exports, is a small contract documented on the attribute in `flutter/private/flutter_native_library.bzl`. `e2e/ffi_example` implements it by hand for a C library (`native/mul_hot_patch.c` and `tools/c_patch_tool.dart`), and its `live 3 × 4` line changes on screen when you edit `native/mul.c` and press `r`. Anything created before a patch keeps the code it was created with, as with Dart closures.

Patches reach apps on macOS, the iOS simulator, iOS devices and Android. Linux, Windows and web apps report the edit the way they did before: stale until restart.

On the web the same wrapper goes in `flutter_web_bundle`'s `native_modules`, which both serves the `.wasm` module and declares it. The situation is the same: the page instantiates the module once and a hot reload does not re-run `main()`. A web hot restart does re-run `main()`, so it re-fetches the module with no relaunch.

## Building for each platform

Every platform has two levels of API:

- **A convenience macro** such as `flutter_macos_app`. It finds the runner files `flutter create` wrote, wires up every internal target, and is what most apps should use.
- **Composable rules** such as `flutter_macos_runner_lib_gen`, for when you need control over a piece the macro decides for you. Each platform section shows them in a collapsed block.

The macros take `flutter create` output as it is. You do not need to edit the generated `Runner` folders.

### App version

`flutter_application` and the Android, iOS, macOS and Windows app macros take `build_name` and `build_number`, Flutter's names for the version that `flutter build --build-name 2.3.4 --build-number 42` sets, and that a `pubspec.yaml` writes as `version: 2.3.4+42`. Unset, they are `flutter create`'s `1.0.0` and `1`. Each platform puts them where its own build does:

| Platform | `build_name` | `build_number` |
|---|---|---|
| Android | `versionName` | `versionCode`: a whole number from 1 to 2100000000 |
| iOS, macOS | `CFBundleShortVersionString`: numbers separated by periods, padded to three as `flutter build` pads them (`2.3` is `2.3.0`) | `CFBundleVersion`: numbers separated by periods |
| Web | `version` in `version.json`, from the application's | `build_number` in `version.json`, from the application's |
| Windows | The executable's version, `<build_name>+<build_number>`, and the first three of its four file version numbers: `MAJOR.MINOR.PATCH`, with an optional `-prerelease` | The fourth file version number: a whole number. Each of the four is at most 65535 |

Linux apps carry no version. A value the platform cannot use fails the build and says what it accepts, where `flutter build` would quietly change it (`0` to `1` on Android, `1.0-beta` to `1.0.0` on iOS, a build number of `1.2` to `0` on Windows).

Each platform's own way of setting the version still works: `version` (an `apple_bundle_version`) on iOS and macOS, `manifest_values` or an `android:versionCode` in your own manifest on Android, `version_json` (or `web/version.json`) on web. Setting a field both ways is an error, rather than one value silently winning.

rules_flutter has no flag for a release version. Give the arguments a `select()` over a flag of your own, whose `None` keeps the default:

```starlark
flutter_android_app(
    name = "my_app_android",
    ...
    build_number = select({
        ":release": "42",
        "//conditions:default": None,
    }),
)
```

On iOS and macOS, rules_apple's `apple_bundle_version` can instead read the version from `bazel build --embed_label=...`; pass it as `version`.

### Flavors

A flavor is a target. Give `flutter_application` a `flavor`, and declare one application per flavor, with the platform target of each beside it:

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app_paid",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    flavor = "paid",
    deps = [...],
)

flutter_macos_app(
    name = "macos_paid",
    application = ":app_paid",
    bundle_id = "com.example.myapp.paid",   # per-flavor app id: an ordinary attribute
    app_name = "My App Paid",
)

flutter_web_app(
    name = "web_paid",
    application = ":app_paid",
    app_name = "My App Paid",
)
```

What `flavor` does, as `flutter build --flavor` does it:

- `appFlavor` (`package:flutter/services.dart`) is `'paid'` in the app. Without `flavor` it is `null`.
- A pub package's `flutter: assets:` or `flutter: shaders:` entry with `flavors: [paid, ...]` is bundled in builds of that flavor, and in no build of another flavor or of none.
- `flutter_bazel run //:macos_paid` runs the paid flavor. There is no `--flavor` flag: the flavor is part of the target, and hot reload and hot restart keep it.

What it does not do. Everything else that differs between flavors, the app id, name, icons, Info.plist, Android manifest and resources, window title, differs because the flavor's platform target sets it. Those are the attributes of the platform macros: `application_id`, `app_name`, `manifest` and `resources` for `flutter_android_app`; `bundle_id`, `app_name`, `info_plist`, `app_icons`, `resources` and `entitlements` for `flutter_ios_app` and `flutter_macos_app`; `application_id`, `app_name` and `window_title` for `flutter_linux_app`; `app_name` for `flutter_windows_app`; `app_name` and `web_dir` for `flutter_web_app`. rules_flutter adds no Gradle product flavors, Xcode schemes or CMake variables, and has no `default-flavor`: set `flavor` on the target.

- The app's own assets come from the target's `assets`, not its pubspec, so a flavor's own assets go in that flavor's target. A library's flavor-only assets go in a small library that only that flavor's application depends on.
- `FLUTTER_APP_FLAVOR` cannot be set by hand: it is refused in `defines` and `--dart-define`, as `flutter build` refuses it.
- Web bundles a flavor's `flavors:` assets and shaders like the other platforms. `flutter build web` has no `--flavor` and bundles none, so this is a deliberate difference.
- `flutter_test` takes `flavor` too, as `flutter test --flavor` does: `appFlavor` is set, and the pub assets and shaders whose `flavors:` name it are bundled for the test. Without it, a test sees no `appFlavor` and no `flavors:` entry.

### macOS

Requires Xcode. Run `flutter create --platforms=macos .` first so `macos/Runner/` exists.

```starlark
load("@rules_flutter//flutter:macos.bzl", "flutter_macos_app")

flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    app_name = "My App",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The macOS bundle identifier. Required. |
| `app_name` | Display name for the menu bar and window title. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"12.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `macos/Runner/Info.plist`. |
| `build_name` | `CFBundleShortVersionString`. Defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | `CFBundleVersion`. Defaults to `"1"`. |
| `version` | An `apple_bundle_version` or `flutter_apple_bundle_version` target, in place of `build_name` and `build_number`. |
| `entitlements` | Replaces the entitlements wiring. By default the macro finds `macos/Runner/DebugProfile.entitlements` and `Release.entitlements` and picks one by compilation mode. |
| `additional_entitlements` | Entitlement plist files merged into the selected base in every compilation mode. See [Release builds and permissions](#release-builds-and-permissions). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `macos/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

The output is a `.app` bundle containing `FlutterMacOS.framework`, `App.framework`, and `flutter_assets/`. The target you name is a thin one in front of `macos_application`: `bazel build //...` skips the app on any platform but macOS (a Linux CI runner), and a `target_compatible_with` you pass is kept beside that. The archive is `<name>.zip`.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:macos.bzl",
    "flutter_entitlements_merge",
    "flutter_macos_engine",
    "flutter_macos_app_framework_gen",
    "flutter_macos_info_plist_gen",
    "flutter_macos_menu_xib_gen",
    "flutter_macos_native_libs_gen",
    "flutter_macos_registrant_gen",
    "flutter_macos_runner_lib_gen")

flutter_macos_app_framework_gen(name = "my_framework", application = ":my_app")
flutter_macos_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_macos_engine(name = "my_engine")
flutter_macos_native_libs_gen(name = "my_native_libs", application = ":my_app")
flutter_macos_info_plist_gen(name = "my_info_plist", app_name = "My App")
flutter_macos_menu_xib_gen(name = "my_menu_xib", app_name = "My App")

flutter_macos_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

# rules_apple's `entitlements` takes one file. This merges additions into it.
# Additions only; a key present in both with different values is an error.
# Also exported from flutter:ios.bzl.
flutter_entitlements_merge(
    name = "my_entitlements",
    base = "macos/Runner/Release.entitlements",
    additions = ["entitlements/Network.entitlements"],
)

macos_application(
    name = "my_macos_app",
    bundle_id = "com.example.myapp",
    additional_contents = {
        ":my_framework": "Frameworks",
        ":my_native_libs": "Frameworks",
    },
    infoplists = [":my_info_plist"],
    resources = [":my_menu_xib"],
    deps = [":my_runner"],
)
```

</details>

### iOS

Requires Xcode. Run `flutter create --platforms=ios .` first so `ios/Runner/` exists, and add `flutter_ios_engine` to `use_repo`.

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_app")

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `bundle_id` | The iOS bundle identifier. Required. |
| `families` | Device families. Defaults to `["iphone"]`, unlike `flutter create` (iPhone and iPad). An iPhone-only app runs in a small window on iPadOS. Adding `"ipad"` needs an icon set without the 76x76@1x iPad icon `flutter create` generates, which `actool` rejects. |
| `app_name` | Display name. Defaults to the target name. |
| `minimum_os_version` | Defaults to `"15.0"`, which is what the prebuilt engine is built for. A lower value is refused rather than warned about. |
| `info_plist` | Replaces the discovered `ios/Runner/Info.plist`. |
| `build_name` | `CFBundleShortVersionString`. Defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | `CFBundleVersion`. Defaults to `"1"`. |
| `version` | An `apple_bundle_version` or `flutter_apple_bundle_version` target, in place of `build_name` and `build_number`. |
| `launch_storyboard` | Replaces the launch storyboard. |
| `entitlements` | Replaces the entitlements wiring. By default the macro uses `ios/Runner/Runner.entitlements` if it exists. An app with no entitlements file is fine. |
| `additional_entitlements` | Entitlement plist files merged into the base in every compilation mode. Works even when the app has no entitlements file. See [Release builds and permissions](#release-builds-and-permissions). |
| `provisioning_profile` | A `.mobileprovision` file, usually a `local_provisioning_profile` target. Required for device builds, unused by simulator builds. See [Running on an iOS device](#running-on-an-ios-device). |
| `app_icons` | Defaults to the `AppIcon.appiconset` in `ios/Runner/Assets.xcassets`. See [App icons](#app-icons). |
| `runner_deps` | `swift_library` targets linked into the runner. See [App Intents](#app-intents). |

`rules_apple`'s `ios_application` handles the transition to iOS arm64. The target you name is a thin one in front of it that keeps the platform of the build: `bazel build //...` skips the app on a platform that is neither macOS nor iOS (a Linux CI runner), and a `target_compatible_with` you pass is kept beside that. The archive is `<name>.ipa`.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:ios.bzl",
    "flutter_entitlements_merge",
    "flutter_ios_engine",
    "flutter_ios_app_framework_gen",
    "flutter_ios_info_plist_gen",
    "flutter_ios_native_frameworks_gen",
    "flutter_ios_registrant_gen",
    "flutter_ios_runner_lib_gen")

flutter_ios_app_framework_gen(name = "my_framework", application = ":my_app")
flutter_ios_registrant_gen(name = "my_registrant", application = ":my_app")
flutter_ios_engine(name = "my_engine")
flutter_ios_info_plist_gen(name = "my_info_plist", app_name = "My App")

# Frameworks for the app's Native Assets and `native_deps` libraries. If you
# leave this out of `deps` below, the app builds and renders normally and
# then fails every native call at runtime.
flutter_ios_native_frameworks_gen(name = "my_native_frameworks", application = ":my_app")

flutter_ios_runner_lib_gen(
    name = "my_runner",
    registrant = ":my_registrant",
    engine = ":my_engine",
)

ios_application(
    name = "my_ios_app",
    bundle_id = "com.example.myapp",
    families = ["iphone"],
    minimum_os_version = "15.0",
    deps = [":my_framework", ":my_native_frameworks", ":my_runner"],
)
```

</details>

#### Running on an iOS device

Simulator builds need no code signing. Device builds need a provisioning profile, which is per-developer and should stay out of version control. `flutter_ios_app` takes it directly:

```starlark
# In a git-ignored //device package, so the credential stays local.
load("@rules_apple//apple:apple.bzl", "local_provisioning_profile")

local_provisioning_profile(
    name = "profile",
    profile_name = "iOS Team Provisioning Profile: *",
    tags = ["manual"],
)
```

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    provisioning_profile = "//device:profile",
)
```

That is the only difference from the simulator target, unless the app ships entitlements its profile cannot grant — see below. `flutter_ios_app` is tagged `manual` by default, so `bazel build //...` on a fresh clone does not try to load the missing `//device` package. `bazel query 'deps(//...)'` still follows the label of a `manual` target into it, so a repository that wants that query to work on a fresh clone points `provisioning_profile` at a `label_flag` whose default is a target that fails with setup steps, and sets the flag to `//device:profile` in `.bazelrc.user`. `e2e/hello_world` does this.

Keep the app target in the committed BUILD file and put only the `local_provisioning_profile` in `//device`. The profile is the one genuinely per-developer fact. If the whole device app lives in a git-ignored package it is invisible to review and CI, and it drifts. Two of this repository's own examples once had a device app that had quietly diverged from its committed simulator twin. The same advice applies if you assemble the app from the composable rules: give the device `ios_application` the same `deps` as the simulator one.

Then run it:

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_ios_device -d ios
```

Each iOS example ships a `device.example/` folder. Copy it to a git-ignored `device/`, set your bundle id, and add `common --//:device_profile=//device:profile` to the example's `.bazelrc.user`.

**Finding the profile's name.** `profile_name` matches the profile's `Name` field, and that is not always `iOS Team Provisioning Profile: <bundle id>`. Xcode mints a per-bundle-id profile only for an App ID registered in the developer portal. For an unregistered id, which most example and scratch apps have, automatic signing issues the team wildcard profile, `iOS Team Provisioning Profile: *`, and that is what covers your bundle id. List what you have:

```sh
for f in ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/*.mobileprovision; do
  security cms -D -i "$f" | plutil -extract Name raw -
done
```

Without `provisioning_profile`, a device build fails at analysis, and the message says that rules_apple needs the profile even for an app it does not sign in that build.

**Signing later.** `flutter build ios --no-codesign` builds an app with no signing identity at hand, for a CI that signs elsewhere. The equivalent here is rules_apple's sign-later flow. Build the device app with `--features=disable_legacy_signing`, which leaves the `.ipa` unsigned, and take the `combined_dossier_zip` output group:

```sh
bazel build //:my_app_ios_device -c opt --ios_multi_cpus=arm64 \
    --features=disable_legacy_signing \
    --output_groups=+combined_dossier_zip
```

The dossier holds what rules_apple's `dossier_codesigningtool` needs to sign the bundle on a machine that has the identity. The profile is still required, because it supplies the bundle's `embedded.mobileprovision` and its entitlements. `--no-codesign` differs here: Xcode leaves the profile out as well, and rules_apple's sign-later model has no equivalent.

**Entitlements your profile cannot grant.** A simulator build is ad-hoc signed and validates nothing. A device build is signed against the profile, and an entitlement the profile does not grant fails it:

```
Target "//:my_app_ios_device" uses entitlements with the "aps-environment" key,
but the profile does not have this key
```

`aps-environment` is the common one. Xcode writes it into `ios/Runner/Runner.entitlements` the moment Push Notifications is enabled, it stays there long after the code that used it is gone, and a team wildcard profile can never grant it — push requires a registered App ID. The message names the profile, so the file is the last place you look, and `flutter_ios_app` discovers it silently because it is on disk. Pass `entitlements = False` on the device target to ship none:

```starlark
flutter_ios_app(
    name = "my_app_ios_device",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    entitlements = False,
    provisioning_profile = "//device:profile",
)
```

Deleting the file is the wrong fix. It is the app's real answer for the profile that *does* grant push, and Xcode will write it again.

**Getting a profile.** This is an Apple Developer account operation, and the rules cannot do it for you. You need a development profile whose App ID matches your `bundle_id`, installed under `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. Either create the App ID and a profile in the developer portal, download it, and double-click it, or let Xcode do it from any project with the right bundle id and automatic signing:

```sh
xcodebuild -project <some>.xcodeproj -scheme <scheme> -configuration Debug \
  -destination generic/platform=iOS \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
```

The project can be a scratch project. It does not need to be the app you build with Bazel, which has no `.xcodeproj` at all. Free "Personal Team" profiles expire after about seven days. When a build fails with "no provisioning profile was found named …", mint a fresh one.

#### Checking an iOS release build

There is no way to run a release iOS build without a signing credential. That matters because release-only problems, such as [missing permissions](#release-builds-and-permissions), show up when you run the app, not when you read the code.

- **Device, `-c opt`.** The real thing. Needs a provisioning profile.
- **Simulator, `-c opt`.** Refused at analysis: "The iOS simulator runs debug builds only". So is the default `fastbuild`. The simulator engine runs kernel under the JIT and cannot load an AOT snapshot, so such a bundle would install, launch, and show a blank white screen with only `Engine run configuration was invalid` in the system log. `flutter build ios --simulator --release` refuses it too.

Use `-c dbg` on the simulator and a device for release. A test that needs a simulator bundle under a plain `bazel test //...` gets one from `flutter_ios_simulator_build`, which builds its `targets` with `-c dbg` whatever the command line says. Name it in a test's `data`, or use `flutter_ios_simulator_build_test` in place of a `build_test`:

```starlark
load("@rules_flutter//flutter:ios.bzl", "flutter_ios_simulator_build_test")

flutter_ios_simulator_build_test(
    name = "ios_app_build_test",
    targets = [":app_ios"],
)
```

### App icons

On Apple platforms the icon comes from an asset catalog. `actool` compiles the catalog and needs to be told which set inside it is the app icon, which is what `rules_apple`'s `app_icons` attribute does and what listing the same PNGs under `resources` cannot. `flutter_ios_app` and `flutter_macos_app` find the `AppIcon.appiconset` that `flutter create` wrote and forward it, so an app that never mentions its icon ships the one in its tree, the same as `flutter build`.

To ship a different icon, pass `app_icons` the files of an `.appiconset` or of an Icon Composer `.icon` bundle. `rules_apple` 4.5+ generates the older sizes from an `.icon` bundle. Name one or the other, not both. `app_icons = []` ships no icon.

Discovery is per platform, and a missing catalog is not an error. A tree made with `flutter create --platforms=ios .` has `ios/Runner/Assets.xcassets` and no macOS counterpart, so the iOS app gets its icon and the macOS app gets the placeholder. If one platform shows your icon and the other does not, check for the catalog first.

macOS icons use the platform's own grid rather than a full-bleed square: the rounded shape sits inset to roughly 824 of the 1024-point canvas, which is what makes it line up with other Dock icons. The rules pass the catalog through untouched.

One `flutter create` quirk is handled for you on macOS. Its `Info.plist` declares `CFBundleIconFile` as an empty string for Xcode to fill in, while `macos_application` generates its own value from the catalog, and Apple's plisttool refuses two different values for one key. The macro drops the empty placeholder. A plist that names a real icon file is left alone, and will still conflict if you also pass `app_icons`.

### App Intents

To ship App Intents, give the Swift library to two attributes. `runner_deps` links it into the runner, so its code is in the binary. rules_apple's `app_intents` (which passes through `**kwargs`) extracts the metadata into the bundle: `Contents/Resources/Metadata.appintents` on macOS, `Metadata.appintents` at the bundle root on iOS. `app_intents` does not link the library, and `runner_deps` does not extract anything, so an app that gives it to only one ships either metadata with no code or code that the system never learns about.

```starlark
swift_library(
    name = "intents",
    srcs = ["Intents/PingIntent.swift"],
    # rules_apple's aspect refuses a library that does not name the framework.
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Intents",
)

flutter_macos_app(
    name = "app",
    app_intents = [":intents"],
    runner_deps = [":intents"],
    # ...
)
```

`e2e/macos_example` and `e2e/ios_example` each build such an app and check the bundle names the intent and the binary links it. When `appintentsmetadataprocessor` fails on a schema validation error, rules_apple's wrapper reports `version.json.sorted: No such file or directory` and hides the processor's own message. Run the processor by hand to read the real error.

### App extensions

Widgets, Control Center controls, share extensions and other app extensions are written in Swift and built with rules_apple's `ios_extension` or `macos_extension`. `flutter_ios_app` and `flutter_macos_app` pass `extensions` through to `ios_application` and `macos_application`, which embed each `.appex` in `PlugIns/` (iOS) or `Contents/PlugIns/` (macOS). Flutter does not run inside an extension: an extension cannot link the Flutter engine or Dart code from these rules. Share data with the app through an App Group instead.

```starlark
load("@rules_apple//apple:ios.bzl", "ios_extension")
load("@rules_flutter//flutter:ios.bzl", "flutter_apple_bundle_version", "flutter_ios_app")
load("@rules_swift//swift:swift.bzl", "swift_library")

# The version of the app and its extension.
flutter_apple_bundle_version(
    name = "version",
    build_name = "2.3.4",
    build_number = "42",
)

swift_library(
    name = "widgets_lib",
    srcs = ["extensions/Widgets.swift"],
    linkopts = ["-Wl,-framework,AppIntents"],
    module_name = "Widgets",
)

ios_extension(
    name = "widgets",
    app_intents = [":widgets_lib"],
    bundle_id = "com.example.myapp.widgets",
    entitlements = "extensions/AppGroup.entitlements",
    families = ["iphone"],
    infoplists = ["extensions/Widgets-Info.plist"],
    minimum_os_version = "17.0",
    version = ":version",
    deps = [":widgets_lib"],
)

flutter_ios_app(
    name = "my_app_ios",
    additional_entitlements = ["extensions/AppGroup.entitlements"],
    application = ":my_app",
    bundle_id = "com.example.myapp",
    extensions = [":widgets"],
    version = ":version",
)
```

What the extension needs:

- **A version equal to the app's.** rules_apple gives an extension no version unless you pass one, and the system expects an extension's version to match its app's. Declare the version once, with `flutter_apple_bundle_version` (from `flutter:ios.bzl` or `flutter:macos.bzl`, taking `build_name` and `build_number`) or rules_apple's `apple_bundle_version`, and pass it as the `version` of the app and of each extension.
- **A bundle id under the app's**, such as `com.example.myapp.widgets`.
- **An Info.plist with the bundle keys.** Besides `NSExtension` and its `NSExtensionPointIdentifier`, give `CFBundleName` (`$(PRODUCT_NAME)`), `CFBundleExecutable` (`$(EXECUTABLE_NAME)`), `CFBundleIdentifier` (`$(PRODUCT_BUNDLE_IDENTIFIER)`) and `CFBundlePackageType` `XPC!`. Without them the simulator refuses to install the app.
- **Its App Intents.** A control's button, an interactive widget or a configurable widget runs an App Intent in the extension, so give the library to the extension's `app_intents` as well as its `deps`. rules_apple 5.4.0's `macos_extension` has no `app_intents` attribute. `e2e/macos_example/patches/` has a patch that adds it; apply it with `single_version_override(module_name = "rules_apple", version = "5.4.0", patch_strip = 1, patches = [...])`. Overrides only apply in the root module, so an app needs the override in its own `MODULE.bazel`; it does not come with rules_flutter.
- **On macOS, a sandbox.** macOS loads a widget or share extension only if its entitlements include `com.apple.security.app-sandbox`.
- **Visibility** to the package of the app target, if it lives elsewhere. `flutter_ios_app` and `flutter_macos_app` must sit in the package that holds `ios/Runner/` or `macos/Runner/`.

An extension can have a higher `minimum_os_version` than the app. rules_apple accepts that without comment and each bundle records its own minimum, so the system skips the extension on an older OS. Control Center controls need iOS 18 or macOS 26; either raise the extension's minimum or include the control in the `WidgetBundle` behind `if #available`, as the examples do.

**App Groups.** Give each extension an `entitlements` file with `com.apple.security.application-groups`, and merge the same file into the app with `additional_entitlements`. A simulator build is not checked against anything, so the group works there. On macOS, the `group.` form needs a provisioning profile that lists the group, and the team-prefixed form (`<TEAM ID>.name`) needs a signature from that team, which a team wildcard profile gives without listing any group. An app signed ad hoc gets neither: it builds, and its extensions register, but writes into the group container are refused.

**Signing.** rules_apple signs each extension in its own target, so the app's `provisioning_profile` does not reach its extensions. Give each extension its own `provisioning_profile`. On macOS, an extension without one is signed with the build's `--@rules_apple//apple/build_settings:signing_certificate_name`, and with none set, ad hoc, so it has no team and loses its App Group even inside a team-signed app. A profile can only grant an App Group if it is made for an explicit App ID that has the group, so a device build with groups needs an App ID and a profile for the app and for each extension, registered in the developer portal. The team wildcard profile (`iOS Team Provisioning Profile: *`) covers any bundle id but grants no App Group, and a device build that asks for an entitlement its profile lacks fails. `e2e/ios_example` has a device variant, `:app_extensions_device`, signed with the wildcard; it leaves the App Group out of the app and its extensions for that reason. On macOS the wildcard is enough with a team-prefixed group: `e2e/macos_example`'s `:app_extensions_team` gives the app and each extension the `Mac Team Provisioning Profile: *` wildcard, and the app writes into its group container. Its profile and group live in a git-ignored `//device` package made from `device.example/`, because the group carries the team id; the app reaches them through the `//:device_profile` and `//:device_app_group` flags, which `.bazelrc.user` sets to `//device:profile` and `//device:AppGroup.entitlements`. A macOS `local_provisioning_profile` needs `profile_extension = ".provisionprofile"`; rules_apple otherwise looks for a `.mobileprovision`. `codesign --verify --deep --strict` passes on an app whose extension was signed ad hoc, so it does not catch a missing profile; compare `TeamIdentifier` across the bundles instead, as `:verify_macos_team_signing_test` does.

`e2e/ios_example` and `e2e/macos_example` each build an app with a widget extension holding a widget and a control, and a share extension, and check where each lands, what each declares, and that all share one App Group.

### Android

Run `flutter create --platforms=android .` first so `android/app/src/main/` exists with its manifest, resources, and Kotlin sources.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app")

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    application_id = "com.example.myapp",
)
```

Add these to `MODULE.bazel`:

```starlark
bazel_dep(name = "rules_android", version = "0.8.1")
bazel_dep(name = "rules_android_ndk", version = "0.1.5")
bazel_dep(name = "hermetic_android_toolchains", version = "0.5.0", dev_dependency = True)

# rules_android_ndk 0.1.5 links arm64 libraries for 4 KB pages: see "16 KB
# pages" below.
git_override(
    module_name = "rules_android_ndk",
    commit = "9946c72d5b617115d34dc2efb334f829c558a87b",
    remote = "https://github.com/bazelbuild/rules_android_ndk.git",
)

use_repo(flutter_pub, "deps")

android = use_extension("@hermetic_android_toolchains//:extensions.bzl", "android", dev_dependency = True)

# The Android platform the app compiles against, and the build tools.
android.sdk(
    build_tools_version = "35.0.0",
    version = "35",
)

# The NDK CC toolchain, used for native and FFI deps built for Android and
# to strip the engine's native libraries, as a Gradle build does. `api_level`
# is your app's `min_sdk_version` (24 unless you set it).
android.ndk(
    api_level = 24,
    version = "r28c",
)
use_repo(android, "androidndk", "androidsdk")

# Every module's `@androidsdk` and `@androidndk` (rules_android's,
# rules_android_ndk's, rules_flutter's) are these.
rules_android_sdk = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
    dev_dependency = True,
)
override_repo(rules_android_sdk, "androidsdk")

rules_android_ndk = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
    dev_dependency = True,
)
override_repo(rules_android_ndk, "androidndk")

register_toolchains(
    "@androidndk//:all",
    "@androidsdk//:all",
    dev_dependency = True,
)
```

and, once you have read and accepted the licences of the Android SDK and NDK, these to `.bazelrc`, naming the versions you accepted:

```bazelrc
common --repo_env=ACCEPTED_ANDROID_SDK_LICENSE_VERSION=35
common --repo_env=ACCEPTED_ANDROID_NDK_LICENSE_VERSION=r28c
```

The androidx and Kotlin jars the app links come pinned by rules_flutter's own lock, so an app whose plugins declare no Maven artifacts needs nothing more. See **Maven dependencies** below for one whose plugins, or whose own Android code, do.

**The SDK and NDK.** [hermetic_android_toolchains](https://github.com/keith/hermetic_android_toolchains) downloads the SDK platform, build tools, platform tools and NDK of the versions you name, each checked against its checksum, so nothing needs to be installed and every machine and CI runner builds with the same tools. It does so for macOS, Linux x86_64 and Windows x86_64 hosts, the hosts Google publishes the NDK for. `r28c` (28.2.13676358) is the NDK Flutter's Gradle plugin builds with. Without the licence lines, the build stops during fetch, saying which line to add:

```
Before using the hermetic Android SDK toolchain you must read and accept the
license for the current version. Once you have done so, add this in your
'.bazelrc':

common --repo_env=ACCEPTED_ANDROID_SDK_LICENSE_VERSION=35
```

On a Mac the downloads are about 1.1 GB, 950 MB of it the NDK, which unpacks to 2.8 GB. Bazel keeps the archives in its repository cache and the unpacked NDK in its repository contents cache, which every workspace on the machine shares; each workspace's output base holds its own 350 MB copy of the SDK.

**Order of the `bazel_dep` lines.** Keep `rules_flutter`'s above `rules_android`'s, as here. rules_android builds some of its tools from Go, with the first Go SDK the module graph declares: your module's own, then each dependency's in the order your `MODULE.bazel` names them. rules_flutter declares one new enough for the Gazelle the graph resolves; rules_android's own, Go 1.22.4, is not, and with rules_android named first, every Android build fails during analysis with `go: go.work requires go >= 1.24.12 (running go 1.22.4; GOTOOLCHAIN=local)`. A `go_sdk.download` in your own `MODULE.bazel` takes precedence over both.

**NDK `api_level`.** Set it to the app's `min_sdk_version`, as Gradle compiles native code at `minSdkVersion`. Your `cc_library` code (an FFI library, a plugin's C code) is built against it, and at a higher level can call functions that older devices lack: such a library installs, and then fails to load there with an unresolved symbol. hermetic_android_toolchains defaults to 31.

**An installed SDK and NDK instead.** rules_android and rules_android_ndk can take the SDK and NDK installed on the machine, found through two environment variables. In `MODULE.bazel`, in place of everything from `hermetic_android_toolchains` down:

```starlark
android_ndk_repository_extension = use_extension(
    "@rules_android_ndk//:extension.bzl",
    "android_ndk_repository_extension",
)

# Your app's `min_sdk_version` (24 unless you set it).
android_ndk_repository_extension.configure(api_level = 24)
use_repo(android_ndk_repository_extension, "androidndk")

register_toolchains("@androidndk//:all")

# The Android platform the app compiles against, rather than the newest one
# installed on the machine.
android_sdk_repository_extension = use_extension(
    "@rules_android//rules/android_sdk_repository:rule.bzl",
    "android_sdk_repository_extension",
)
android_sdk_repository_extension.configure(api_level = 35)
use_repo(android_sdk_repository_extension, "androidsdk")
```

Without `configure(api_level = ...)`, rules_android compiles against the newest Android platform installed on the machine, so two machines can build the same app differently: a newer `android.jar` can, for instance, mark a method a plugin's Kotlin calls `@Nullable` and fail its compile. Name a platform you have installed. rules_android_ndk's `api_level` defaults to 31, and the root module's `configure` is the one that counts; a dependency's is ignored. Both variables are read by repository rules while Bazel fetches:

| Variable | Value | Read by |
|---|---|---|
| `ANDROID_HOME` | The SDK root, for example `~/Library/Android/sdk`. | `rules_android` |
| `ANDROID_NDK_HOME` | A versioned NDK directory, for example `$ANDROID_HOME/ndk/28.2.13676358`. | `rules_android_ndk` |

`ANDROID_NDK_HOME` has to name the versioned directory, not the `ndk/` folder above it. Pointing at the parent fails with a message that mentions neither the variable nor the mistake:

```
Error in readdir: can't readdir(), not a directory:
  .../Android/sdk/ndk/toolchains/llvm/prebuilt/darwin-x86_64
```

Exporting the variables in your shell works. To put them in `.bazelrc`, use `--repo_env`. `--action_env` only reaches build actions, and repository rules never see it:

```bazelrc
common --repo_env=ANDROID_HOME=/path/to/Android/sdk
common --repo_env=ANDROID_NDK_HOME=/path/to/Android/sdk/ndk/28.2.13676358
```

With `ANDROID_NDK_HOME` unset, the build stops during fetch:

```
ERROR: An error occurred during the fetch of repository
  'rules_android_ndk++android_ndk_repository_extension+androidndk':
  Error in fail: Either the ANDROID_NDK_HOME environment variable or the
  path attribute of android_ndk_repository must be set.
```

**Building on Windows.** rules_android 0.8.1 starts its tool JVMs with an initial heap as large as their cap (`-Xms3G` for resource processing, `-Xms8g` for desugaring, D8 and R8), and a JVM commits its initial heap as it starts. Windows counts that against RAM plus the pagefile whether or not the JVM uses it, so on a 16 GB machine a few of them running at once fail the build with `There is insufficient memory for the Java Runtime Environment to continue` and `The paging file is too small for this operation to complete`. Apply `rules_android_no_initial_heap.patch` from [`e2e/android_example/patches/`](e2e/android_example/patches/) in your `single_version_override` of rules_android, as that workspace's `MODULE.bazel` does. It keeps each heap cap and drops only the initial sizes. macOS and Linux build without it.

**Maven dependencies.** The androidx and Kotlin jars the runner and plugins compile against come from `@rules_flutter_maven`, rules_flutter's own rules_jvm_external repository: one resolution of the app's Android libraries, as Gradle makes one per app. rules_flutter declares the embedding's artifacts in it with a lock of its own, and an app that needs no others uses that lock: each jar is fetched by checksum and kept in Bazel's repository cache, so a fresh output base or CI runner does not download it again.

When your plugins declare Maven artifacts, or your own Android code (a `kt_android_library` beside the app, say) needs some, declare an install of the same name in your root `MODULE.bazel`, with the artifacts and a lock file of your own:

```starlark
bazel_dep(name = "rules_jvm_external", version = "7.2")

maven = use_extension("@rules_jvm_external//:extensions.bzl", "maven")
maven.install(
    name = "rules_flutter_maven",
    artifacts = ["androidx.browser:browser:1.9.0"],
    known_contributing_modules = ["rules_flutter"],
    lock_file = "//:rules_flutter_maven_install.json",
    repositories = [
        "https://maven.google.com",
        "https://repo1.maven.org/maven2",
    ],
)
use_repo(maven, "rules_flutter_maven")
```

Then create the lock and fill it: `touch rules_flutter_maven_install.json && REPIN=1 bazel run @rules_flutter_maven//:pin`. rules_jvm_external merges your artifacts with rules_flutter's into the one resolution and the lock pins both; your code depends on them as `@rules_flutter_maven//:androidx_browser_browser`, the labels rules_jvm_external gives every artifact. Depend on no other repository's copy of a library the app links: the build fails when one Maven library reaches the app from two repositories (see [Plugins' Maven dependencies](#plugins-maven-dependencies)). `known_contributing_modules` lists the other modules whose artifacts join yours. Without it rules_jvm_external prints a notice naming them each time it evaluates the extension, and with it only the listed modules contribute: a module you add later that declares artifacts for `rules_flutter_maven` has to be added to the list. `repositories` replaces the default, Maven Central alone, which lacks the androidx artifacts.

Run `REPIN=1 bazel run @rules_flutter_maven//:pin` again after changing the artifacts, or bumping rules_flutter: Bazel fails the build until you do. rules_android's own tools resolve in its own repository, `@rules_android_maven`, with the lock it ships, and need nothing from you. [`e2e/plugin_example/MODULE.bazel`](e2e/plugin_example/MODULE.bazel) is a worked example for plugins, and [`e2e/android_example/MODULE.bazel`](e2e/android_example/MODULE.bazel) for an app's own Kotlin code.

**ABIs.** The ABIs of the APK are the platforms of `--@rules_android//flags:android_platforms`, as for any rules_android `android_binary`. One platform builds an APK for that ABI; several build one APK for all of them, like the fat APK `flutter build apk` makes. The Flutter engine, the app's `libapp.so`, the native libraries of the AARs your plugins bring and any C/C++ deps are each packaged for every ABI, from one mechanism: `android_binary` builds its dependencies once for each platform and packages what each build brings.

```sh
# arm64 phones
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a

# x86_64 emulators
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:x86_64

# 32-bit ARM phones
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a

# one APK for all three, as `flutter build apk`'s default
bazel build //:my_app_android \
    --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64
```

The platforms are rules_android's own, `@rules_android//:armeabi-v7a`, `@rules_android//:arm64-v8a` and `@rules_android//:x86_64`, and are named for their ABI because rules_android packages a platform's native libraries into `lib/<platform name>/`. Write them as shown: the flag's value is read by rules_android, which resolves the label from its own repository, so a platform of your own repository, or `@rules_flutter//...`, is not found. The engine of each ABI comes with rules_flutter; nothing of it goes in your `use_repo`.

The flag is rules_android's Starlark flag, which rules_android reads first. The short `--android_platforms` also works: rules_android aliases it to that flag (`flag_alias`), and Bazel's native option of the same name is what rules_android falls back to while it exists. The long form names `@rules_android` on the command line, so your root `MODULE.bazel` needs `bazel_dep(name = "rules_android", version = "0.8.1")`.

Put the platforms you usually build for in your `.bazelrc`, with a config for the others:

```bazelrc
common --@rules_android//flags:android_platforms=@rules_android//:arm64-v8a
common:android-emulator --@rules_android//flags:android_platforms=@rules_android//:x86_64
common:android-fat --@rules_android//flags:android_platforms=@rules_android//:armeabi-v7a,@rules_android//:arm64-v8a,@rules_android//:x86_64
```

With no `--@rules_android//flags:android_platforms`, rules_android builds for `--platforms`, your machine's, and the engine and the bundle are incompatible with it: building the app fails with "incompatible", naming the platform that did not satisfy the constraint. `bazel build //...` on such a platform skips them, and whatever depends on them, with nothing to tag. `flutter_bazel run -d <android device>` asks the device its ABI and passes the matching platform itself.

To build an app for fixed ABIs whatever the command line says, wrap it in [`flutter_android_build`](#flutter_android_build), as a test of the APK for one ABI, or for both, does.

**Core library desugaring.** rules_android turns core library desugaring on for every `android_binary` unless told otherwise: calls to `java.time`, `java.util.stream` and the other Java APIs newer than the app's minimum SDK are rewritten onto a backport (desugar_jdk_libs, the `j$.*` classes), and the whole backport goes into the APK and the App Bundle, about 2.6 MB of dex, unshrunk even when R8 shrinks the rest. A Flutter app built with Gradle has none of it, because core library desugaring is off until the app sets `isCoreLibraryDesugaringEnabled`, and the Flutter embedding and the androidx libraries it uses do not need it at minimum SDK 24. Turn it off in your `.bazelrc`:

```bazelrc
common --@rules_android//flags:desugar_java8_libs=false
```

It is a build-wide flag of rules_android's, so only your project can set it; `flutter_android_app` cannot. Leave it on if your own Android code, or a plugin's, calls one of those APIs: a plugin that does says in its setup to enable `isCoreLibraryDesugaringEnabled`.

**16 KB pages.** Devices with 16 KB memory pages, which Android 15 introduced, refuse a native library whose segments are aligned for 4 KB ones, and the app dies on launch. A Gradle build gets 16 KB alignment from NDK r28 and later. Bazel links an Android app's C/C++ code with the Android C/C++ toolchain, and rules_flutter leaves the alignment to it. rules_android_ndk 0.1.5's toolchain, which the downloaded NDK's toolchains are made from too, links every arm64 library for 4 KB pages; upstream fixed it in commit `efc0c191`, which no release has yet. Until one does, pin rules_android_ndk to a commit of its main branch with the fix, with the `git_override` the `MODULE.bazel` lines above carry. For arm64-v8a and x86_64 the build checks the native libraries the application and its plugins bring, prebuilt ones inside the plugins' AARs included, and fails naming any that is aligned for 4 KB pages, or whose `GNU_RELRO` segment ends partway through a 16 KB page that holds writable data after it (such a library loads, and crashes when it writes that data), the two checks of Android's [16 KB page size guide](https://developer.android.com/guide/practices/page-sizes). A 16 KB-aligned library loads on a 4 KB device too. An app that does not need 16 KB support, because it runs only on 4 KB devices or sets `android:pageSizeCompat` for Android 16's page size compatibility mode, can build with `--@rules_flutter//flutter:allow_4kb_aligned_native_libraries`, which turns both checks off. Google Play requires 16 KB support of apps that target Android 15 or later.

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `application_id` | The application id, Gradle's `applicationId`, for example `"com.example.myapp"`. Required. |
| `namespace` | The package the runner's code declares (Gradle's `namespace`). Relative class names in the manifest (`.MainActivity`, `.sub.Receiver`, `MainActivity`) are written out in full against it, as AGP does. Defaults to `application_id`. |
| `app_name` | Display name. Defaults to the target name. |
| `min_sdk_version` | Minimum Android SDK version. Defaults to 24, Flutter's `flutter.minSdkVersion` and the engine's own minimum. |
| `target_sdk_version` | Target Android SDK version. |
| `build_name` | `versionName`. Defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | `versionCode`. Defaults to `"1"`. |
| `manifest_values` | Values for `${...}` placeholders in the manifest, as `android_binary` takes them. `applicationId`, `minSdkVersion` and `targetSdkVersion` come from the attributes above and cannot be set here; `versionCode` and `versionName` only while `build_number` and `build_name` are unset. |
| `manifest` | A manifest you wrote yourself, used verbatim. Placeholders like `${applicationName}` are not substituted, so do not pass `flutter create`'s own manifest here; let the macro discover that one. |
| `debug_manifest` | A variant manifest whose permissions merge into `-c dbg` builds only. `None` (default) discovers `android/app/src/debug/AndroidManifest.xml`. A label overrides discovery. `False` disables variant handling. |
| `profile_manifest` | The same for profile builds. `None` (default) discovers `android/app/src/profile/AndroidManifest.xml`. |
| `permissions` | Permission names added to the manifest in every compilation mode, for example `["android.permission.INTERNET"]`. See [Release builds and permissions](#release-builds-and-permissions). |
| `multidex` | Defaults to `"native"`. |
| `proguard_specs` | The R8 configuration. By default a release build (`-c opt` without `--@rules_flutter//flutter:profile`) is shrunk with R8, resources too, as `flutter build apk --release` shrinks it: [`@rules_flutter//flutter:android_proguard_rules.pro`](flutter/android_proguard_rules.pro) (the Android Gradle plugin's `proguard-android-optimize.txt` and Flutter's own rules), then `android/app/proguard-rules.pro` if you have one. Debug and profile builds are not shrunk. A list replaces the whole default in every compilation mode; `[]` turns R8 off. |
| `app_bundle` | Also declare an App Bundle of the app under this name. See [Release: App Bundle and signing](#release-app-bundle-and-signing). |
| `bundle_config` | The bundletool `BundleConfig` of `app_bundle`. Defaults to [`@rules_flutter//flutter:android_bundle_config.pb.json`](flutter/android_bundle_config.pb.json), the Android Gradle plugin's: split by ABI, screen density and language, native libraries and dex stored uncompressed, the libraries 16 KB-aligned. |

#### Release: App Bundle and signing

`flutter build appbundle` and `flutter build apk --release` have one counterpart: an App Bundle declared by `flutter_android_app`, and a [`flutter_android_release`](#flutter_android_release) target that signs it with your upload key.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_app", "flutter_android_release")

flutter_android_app(
    name = "app",
    application = ":app_flutter",
    application_id = "com.example.myapp",
    build_name = "1.2.3",
    build_number = 7,
    app_bundle = "app_bundle",
)

flutter_android_release(
    name = "app_release",
    app_bundle = ":app_bundle",
)
```

```sh
# First time only: make the upload keystore android/key.properties describes.
bazel run //:app_release -- create-key

# Each release: build, sign and check the bundle and the APK.
bazel run //:app_release
# -> build/app/outputs/bundle/release/app-release.aab
# -> build/app/outputs/flutter-apk/app-release.apk
```

- `:app_bundle` is built by rules_android's `android_application`, from the same arguments as `:app`. `bazel build //:app_bundle` makes `app_bundle_unsigned.aab` for the ABIs and compilation mode of the command line, like the APK.
- `bazel run //:app_release` builds the bundle in release mode (`-c opt`, not profile) for armeabi-v7a, arm64-v8a and x86_64, whatever the command line says, as `flutter build appbundle` builds every ABI. Its `android_platforms` attribute changes the ABIs.
- Signing happens when the program runs, not in a build action. The keystore and its passwords never reach Bazel: no attribute, action input, command line or cache entry holds them. rules_android has no release signing of its own, by design.
- The key comes from `android/key.properties` under the target's package, the file Flutter's deployment guide has you write:

  ```properties
  storePassword=...
  keyPassword=...
  keyAlias=upload
  storeFile=/Users/me/keys/upload-keystore.jks
  ```

  A relative `storeFile` is relative to `android/app/`, as in Gradle. Never commit the file or the keystore (`flutter create`'s `android/.gitignore` already ignores `key.properties` and `*.jks`). On CI, write the file from your secret store before `bazel run`. `--key-properties=<path>` reads another file, and `--output-dir=<dir>` writes `app-release.aab` and `app-release.apk` there instead.
- `create-key` makes the keystore `storeFile` names (PKCS12, RSA 2048, valid 10000 days, the values in Flutter's guide), with the JDK Bazel already has, so you need no Java installed. It refuses to replace an existing keystore. Back up the keystore and its password: a lost upload key can be reset through Play Console, but only by asking.
- With Play App Signing, the bundle you upload is signed with the upload key, and Google signs the APKs it serves with the app signing key it keeps. `app-release.apk` is for distribution outside Play; it is the APK of the same release build, signed with the same key (by the Android SDK's `apksigner`, which `flutter_android_release` takes from `@androidsdk`), so it will not update a copy installed from Play. As in Gradle's, its native libraries are stored uncompressed and 16 KB-aligned.
- Raise `build_number` for each upload: Play refuses a version code it has seen.

`bazel run //:app_bundle` installs the bundle on the device `ANDROID_SERIAL` names (or the only one connected), through bundletool and signed with the debug key. The JDK, bundletool, `aapt2` and `adb` all come from the build, so nothing needs to be on your PATH.

A release bundle carries R8's mapping (`BUNDLE-METADATA/com.android.tools.build.obfuscation/proguard.map`), from which Play deobfuscates the Java and Kotlin frames of crash reports, as a Gradle-built bundle does.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:android.bzl",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_gen",
    "flutter_android_manifest_merge",
    "flutter_android_permissions_manifest",
    "flutter_android_runner_lib_gen")
load("@rules_android//android:rules.bzl", "android_binary")

flutter_android_bundle(name = "my_bundle", application = ":my_app")
flutter_android_engine(name = "my_engine")

# The bundle's libraries, as the cc_library android_binary takes the native
# libraries of each ABI from.
filegroup(
    name = "my_native_libs_files",
    srcs = [":my_bundle"],
    output_group = "native_libs",
)

cc_library(name = "my_native_libs", srcs = [":my_native_libs_files"])
flutter_android_manifest_gen(name = "my_manifest", application_id = "com.example.myapp")

flutter_android_runner_lib_gen(
    name = "my_runner",
    namespace = "com.example.myapp",
    engine = ":my_engine",
)

android_binary(
    name = "my_apk",
    manifest = ":my_manifest",
    multidex = "native",
    # Stored uncompressed, as the manifest's android:extractNativeLibs="false"
    # requires: Android refuses to install the APK otherwise.
    nocompress_extensions = [".so"],
    deps = [":my_native_libs", ":my_engine", ":my_runner"],
)
```

`flutter_android_bundle` output groups:

| Group | Contents |
|---|---|
| `native_libs` | `libapp.so` (AOT code) plus any `native_deps` libraries |
| `flutter_assets` | The `flutter_assets/` tree |
| `mobile_install` | JNI-structured symlinks and assets for `bazel mobile-install` |

An App Bundle from these rules is rules_android's `android_application`, given the same arguments as the `android_binary` and `bundle_config_file = "@rules_flutter//flutter:android_bundle_config.pb.json"`. `bazel build` of it works, and `flutter_android_release` signs it. `bazel run` of it does not install it: rules_android's run script looks for the JDK where the build ran, gives bundletool no `aapt2`, runs bundletool without the Kotlin runtime its `install-apks` needs, and takes `adb` from your PATH. To install a bundle on a device, declare the app with `flutter_android_app` and its `app_bundle`, whose `bazel run` takes all those tools from the build (see [Release: App Bundle and signing](#release-app-bundle-and-signing)), or install the APK, which `bazel run` of an `android_binary` does.

</details>

### Linux

Run `flutter create --platforms=linux .` first. If `linux/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:linux.bzl", "flutter_linux_app")

flutter_linux_app(
    name = "my_app_linux",
    application = ":my_app",
    application_id = "com.example.myapp",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |
| `application_id` | The application id GTK names the app by, as `flutter create`'s `APPLICATION_ID`. Required: the desktop identifies an app by it, so each app has its own. |
| `window_title` | Window title. Defaults to `app_name`, then the target name. A `linux/runner/` from `flutter create` sets its own title and ignores this. |

The output directory:

```
my_app/
  my_app                     GTK runner executable
  lib/
    libapp.so                AOT-compiled Dart
    libflutter_linux_gtk.so  Flutter engine
    *.so                     native plugin libraries, if any
  data/
    flutter_assets/          fonts, images, shaders, asset manifest
    icudtl.dat               ICU data
```

**GTK3 and your C++ toolchain.** rules_flutter ships its own hermetic sysroot for the GTK3 headers and libraries, and links those libraries as explicit files. It adds no `-L` and no `-lgtk-3` flags. Your toolchain's `--sysroot` stays the only owner of libc, libm, and the rest of the C runtime. This matters because a Debian sysroot's `libm.so` is a linker script with absolute paths that `lld` rewrites only for scripts under `--sysroot`; a second sysroot on the search path would break `-lm` with a "no such file" error naming a file that exists.

**Cross-compiling from macOS** works in debug mode only, because Flutter publishes no cross-compiling `gen_snapshot` for desktop targets. See [Cross-compiling](#cross-compiling).

```sh
bazel build //:my_app_linux -c dbg --platforms=@rules_flutter//flutter/platforms:linux_x64
```

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:linux.bzl",
    "flutter_linux_bundle",
    "flutter_linux_engine",
    "flutter_linux_registrant_gen",
    "flutter_linux_runner_lib_gen")

flutter_linux_engine(name = "flutter_engine")
flutter_linux_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_linux_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
    application_id = "com.example.myapp",
)

flutter_linux_bundle(
    name = "my_linux_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Windows

Run `flutter create --platforms=windows .` first. If `windows/runner/` is missing, the rules use a built-in runner.

```starlark
load("@rules_flutter//flutter:windows.bzl", "flutter_windows_app")

flutter_windows_app(
    name = "my_app_windows",
    application = ":my_app",
)
```

| Attribute | Description |
|---|---|
| `application` | A `flutter_application` target. Required. |
| `app_name` | Binary name. Defaults to the target name. |
| `build_name` | The version, `MAJOR.MINOR.PATCH`. Defaults to `"1.0.0"`. See [App version](#app-version). |
| `build_number` | The fourth version number. Defaults to `"1"`. |

The executable carries what `windows/runner/` gives it, as with `flutter build windows`: `Runner.rc` is compiled into its icon and version information (`build_name+build_number`, with the file version `MAJOR.MINOR.PATCH.BUILD`), and `runner.exe.manifest` is embedded. The built-in runner has the `flutter create` icon and manifest.

Compiling `Runner.rc` takes a Windows resource compiler, registered for Bazel's `@bazel_tools//tools/res:toolchain_type`. On a Windows host with Visual Studio Build Tools, Bazel registers the Windows SDK's `rc.exe` itself, so there is nothing to do. Building for Windows from another host fails until your `MODULE.bazel` registers one, such as `llvm-rc`, wrapped in `windows_resource_compiler_toolchain` from `@bazel_tools//tools/res:winsdk_toolchain.bzl`; rules_flutter registers none, so the choice stays with your module.

The output directory:

```
my_app/
  my_app.exe             Win32 runner executable
  flutter_windows.dll    Flutter engine
  app.so                 AOT-compiled Dart, as ELF
  data/
    flutter_assets/      fonts, images, shaders, asset manifest
    icudtl.dat           ICU data
```

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:windows.bzl",
    "flutter_windows_bundle",
    "flutter_windows_engine",
    "flutter_windows_registrant_gen",
    "flutter_windows_resources",
    "flutter_windows_runner_lib_gen")

flutter_windows_engine(name = "flutter_engine")
flutter_windows_registrant_gen(name = "app_registrant", application = ":my_app")

flutter_windows_resources(
    name = "my_resources",
    rc = "windows/runner/Runner.rc",
    srcs = glob(["windows/runner/*.h", "windows/runner/resources/**"]),
    build_name = "1.2.3",
    build_number = "4",
)

flutter_windows_runner_lib_gen(
    name = "my_runner",
    engine = ":flutter_engine",
    registrant = ":app_registrant",
    srcs = glob(["windows/runner/*.cpp"]),
    hdrs = glob(["windows/runner/*.h"]),
    resources = [":my_resources"],
    manifest = "windows/runner/runner.exe.manifest",
    build_name = "1.2.3",
    build_number = "4",
)

flutter_windows_bundle(
    name = "my_windows_app",
    application = ":my_app",
    runner = ":my_runner",
)
```

</details>

### Web

Run `flutter create --platforms=web .` first so `web/` has its `index.html`, `manifest.json`, and icons. Any of those that are missing are replaced by built-in templates. Add `flutter_web_sdk` to `use_repo`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:web.bzl", "flutter_web_app")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["@deps//:flutter", "@rules_flutter//flutter:material_icons"],
)

flutter_web_app(
    name = "my_app_web",
    application = ":app",
    app_name = "My App",
)
```

The web app takes its `application` like every other platform's, and one application serves them all: its `main`, `deps`, assets, shaders, `defines`, `flavor`, `build_name` and `build_number` are the web app's program and version. The web app compiles that program from source with dart2wasm and dart2js rather than from the application's AOT output, building it once for each compiler's web platform (see [Per-compiler code](#per-compiler-code)). The application's native parts, its AOT compile, `native_deps`, code assets and link hooks, are not built for the web, as `flutter build web` builds no native code; a web app serves WebAssembly modules through `native_modules` instead.

An application whose code imports web-only libraries (`dart:js_interop`, `package:web`, `dart:ui_web`) without a conditional import cannot be built for the Dart VM, which `bazel build //...` otherwise does in its own configuration. Mark it web-only so `bazel build //...` skips it there, while each web app still builds it for its compilers:

```starlark
flutter_application(
    name = "app",
    ...
    target_compatible_with = select({
        "@rules_dart//dart/constraints:vm": ["@platforms//:incompatible"],
        "//conditions:default": [],
    }),
)
```

| Attribute | Description |
|---|---|
| `application` | The `flutter_application` (or `flutter_application_variant`) the web app is built from. Required. Its `build_name` and `build_number` are `version` and `build_number` in the bundle's `version.json`, which the web `package_info_plus` reads (see [App version](#app-version)). |
| `app_name` | Used for the HTML title and manifest. Defaults to the target name. |
| `base_href` | Substituted for `$FLUTTER_BASE_HREF` in `web/index.html`. Defaults to `"/"`. `flutter_bazel run -d chrome` serves the app under it, as `flutter run` does. |
| `extra_web_assets` | Extra files copied into the bundle root, for generated files the `web/` glob cannot see. |
| `web_dir` | The directory the runner files are discovered in and served from at the bundle root. Defaults to `"web"`. Give each app its own, such as `"web_apps/reminders"`, to build several web apps from one package. `flutter_web_bundle` takes it too. |
| `pwa` | Ship `flutter_service_worker.js` and register it. Defaults to `True`. The worker adds no offline caching. Like `flutter build web`, which [deprecated its caching worker](https://github.com/flutter/flutter/issues/156910), it unregisters itself and reloads its clients, which frees visitors still holding a caching worker from an older deployment. |

The macro always compiles with dart2wasm and renders with skwasm. Compiler settings such as `optimization_level_wasm` and `minify_wasm` pass through to `flutter_web_bundle`. For dart2js or CanvasKit, use `flutter_web_bundle` directly.

The built bundle has two builds, as `flutter build web --wasm` does: `main.dart.wasm` (with `main.dart.mjs`) rendered by skwasm, and `main.dart.js` rendered by CanvasKit. The bootstrap lists the WASM build first. Flutter's loader (`flutter.js`) picks the first entry the browser can run, so a browser that cannot run WASM gets the JavaScript build. A browser cannot run the WASM build when it lacks WasmGC, or when, because the renderer is skwasm, its engine is not allowed to use it. `flutter.js` allows skwasm on Chromium only by default (its `wasmAllowList` is `blink: true, gecko: false, webkit: false`), so Firefox and Safari run the JavaScript build unless you allow them. Measured: Safari 27 loaded `main.dart.js` from a default bundle and rendered it.

Two settings change that:

- `wasm_browsers` names the engines allowed to run the skwasm build: `wasm_browsers = ["blink", "gecko", "webkit"]` serves WebAssembly to Chrome and Edge (`blink`), Firefox (`gecko`) and Safari (`webkit`). Exactly the engines named are allowed. Unset is Flutter's default. It is your judgement of those browsers' skwasm support, not something the rule decides (Safari 27 loaded `main.dart.wasm` and rendered it with `wasm_browsers` naming `webkit`). It sets `wasmAllowList` in the generated bootstrap, so it is refused alongside a `bootstrap_js` of your own (pass `config: {wasmAllowList: {...}}` to `_flutter.loader.load` there) and wherever there is no skwasm build (`compiler = "dart2js"`, `renderer = "canvaskit"`).
- `js_fallback = False` makes the bundle WebAssembly only: no dart2js compile runs, and nothing the rule generates refers to `main.dart.js`. That is for an app that cannot compile under dart2js. `flutter_bazel run -d chrome` then runs such an app under dart2wasm rather than DDC, since DDC compiles JavaScript the app never ships (see `--wasm` below); JavaScript is otherwise for the dev loop, which compiles with DDC. Code that only works under WebAssembly then builds: dart2js refuses the largest 64-bit integer literal at compile time and throws on `Int64List` at runtime, and the default build fails on the first (`e2e/web_example/int64/wasm_only` is an app that uses both, with `js_fallback = False`). If only part of the app needs WebAssembly, give dart2js its own variant of that part instead and keep the fallback (see Per-compiler code below). `js_fallback = False` also halves the compile work, and `optimization_level_js`, `minify_js`, `frequency_based_minification` and `dump_info` are refused, since nothing would run them.

The cost of `js_fallback = False` is the browsers that cannot run WASM, and under the default allow-list that is Firefox and Safari. The loader logs `Flutter Web: no compatible build found for this browser.` and rejects the promise `_flutter.loader.load` returns. The generated `flutter_bootstrap.js` catches that and shows "This app could not start. It is built for WebAssembly only, so it needs a browser that can run it." on the page, where the loader alone would leave the page as `index.html` left it, with no app and no word why. A bundle with the JavaScript build shows a plainer "could not start" message for any load failure. (A `bootstrap_js` of your own gets none of this unless it does the same.) Combining `js_fallback = False` with `wasm_browsers` naming the engines you want is the usual WASM-only deployment.

#### Per-compiler code

A bundle compiles its program once for each compiler it ships: dart2wasm, dart2js for the fallback, and DDC for `flutter_bazel run -d chrome` (DDC compiles what dart2js does, so a debug bundle has two versions of the program at most). The program can differ between them. Dart's own way to do that is a conditional import on `dart.library.js_interop`, but it cannot give dart2js and dart2wasm different declared types or different files. For that, each compiler builds its dependencies for its own web platform, one carrying the constraint value `@rules_dart//dart/constraints:wasm` or `:js`, and a library picks its variant with a `select()` on those in its `deps`. This is [rules_dart's mechanism](https://github.com/aran/rules_dart#per-compiler-code); a Flutter app uses it through `flutter_library` and `flutter_plugin` the same way.

```starlark
# ids_typed/BUILD.bazel, and ids_js/BUILD.bazel the same with its own
# lib/ids.dart: the same API, a different type.
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ids",
)

flutter_library(
    name = "ids",  # typedef Ids = Int64List (in ids_js, List<int>)
    srcs = ["lib/ids.dart"],
    package = ":pubspec-metadata",
)

# ids/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "ids_select",
)

flutter_library(
    name = "ids",
    package = ":pubspec-metadata",
    deps = select({
        "@rules_dart//dart/constraints:js": ["//ids_js"],
        # dart2wasm, and a build for no web platform (the VM's).
        "//conditions:default": ["//ids_typed"],
    }),
)

# BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "app",
)

flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["//ids", "@deps//:flutter"],
)

flutter_web_app(
    name = "app_web",
    application = ":app",
)
```

The `select()` goes in a library, not in the application's `deps`: a `select()` is resolved in the configuration of the target that holds it, and the application's own `deps` are read in the configuration the web app was asked for, not a web platform's. The variants are separate libraries whose `dart_package_metadata` state the same `package_name`, each in a directory of its own, so the import is the same whichever is picked. `e2e/web_example/int64` is this app, which renders `Int64List max: 9223372036854775807` from the WebAssembly build and `List<int> max: 9007199254740991` from the JavaScript one.

What the bundle holds once comes from the primary compiler's version of the program (`dart2wasm` for the default `compiler`): the plugin registrant, the assets and shaders, and the icon tree-shaking scan. A dependency that differs by compiler should not differ in what plugins or assets it brings. An icon only the other compiler's variant uses is shaken out of the font unless `tree_shake_icons = False`.

These are built once, however many compilers reach them: pub packages (and Flutter SDK packages), anything a `flutter_library` or `flutter_plugin` marks `runtime_independent = True`, `flutter_native_library`, `dart_code_asset`, `flutter_data_asset`, `flutter_gen_l10n`, and `dart_codegen` and its siblings. Code generation therefore cannot vary by compiler; a generator that needs to emit a variant per compiler emits both, and the library above chooses. Only the first-party libraries on the path from the bundle to a `select()` are analysed once per compiler, and a library has no action, so that costs analysis time only.

A library that has no variant outside the web says so with `target_compatible_with = select({"@rules_dart//dart/constraints:js": [], "@rules_dart//dart/constraints:wasm": [], "//conditions:default": ["@platforms//:incompatible"]})`, as in rules_dart, so `bazel build //...` skips it rather than failing on it.

The platforms are rules_dart's `@rules_dart//dart/platforms:js` and `:wasm`, which carry only that constraint. A bundle builds for others when its `js_platform` or `wasm_platform` names them; each must carry the matching constraint, and the bundle refuses one that does not.

A bundle has a `canvaskit/` directory of renderer files only when something loads it. By default `flutter.js` fetches the renderer from `www.gstatic.com` and never reads a local copy, so the directory would be dead weight and is not shipped. Two things put it there: `use_local_canvaskit = True`, which also tells the loader to read it, and a debug build, whose dev loop renders with CanvasKit served from it. A `bootstrap_js` of your own that points `canvasKitBaseUrl` at the bundle must set `use_local_canvaskit = True` too, or the directory is not there to load; one attribute states "this bundle serves its own renderer" for both routes, where a second could disagree with the files it ships.

What the directory holds depends on the builds. The loader never falls from skwasm to CanvasKit or back, in or out of cross-origin isolation (skwasm runs single-threaded from the same `skwasm.js` and `skwasm.wasm` when the page is not isolated), so a WASM-only skwasm bundle carries `skwasm*` (Safari and Firefox load `skwasm_heavy*`) and `wimp*` and no CanvasKit, a CanvasKit bundle the reverse, and a bundle with both builds both. The `.symbols` files beside them are emscripten's function-name maps, and nothing fetches them (the dev loop and release runs, skwasm and CanvasKit, were watched request by request), so they are never shipped. They are an output group instead: `bazel build //my:app --output_groups=symbols` links them under `bazel-bin/my/<name>_symbols/canvaskit/`, for the engine this bundle runs, when you need to symbolize a crash.

An optimizing wasm compile (`-O1` and up, the default outside debug) reserves 4 CPUs, and its optimizer uses no more. `--@rules_flutter//flutter:wasm_opt_cpus=N` changes both. Fewer lets several web apps compile at once where Bazel has few CPUs to hand out; more makes one compile finish sooner. The output is the same either way.

The files under `web/` are treated as templates and substituted the way `flutter build web` substitutes them, so raw `flutter create` output works unchanged: `web/index.html`, `web/flutter_bootstrap.js`, `web/manifest.json`, and `web/version.json` are each discovered when present, and everything else under `web/` is copied into the bundle root.

<details>
<summary>Composable rules</summary>

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:web.bzl", "flutter_web_bundle")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    deps = ["@deps//:flutter"],
)

# WASM, with a dart2js build beside it for browsers that cannot run WASM
# (the default):
flutter_web_bundle(
    name = "my_app_web",
    application = ":app",
)

# WASM only, for an app dart2js cannot compile, served to every engine:
flutter_web_bundle(
    name = "my_app_web_wasm",
    application = ":app",
    js_fallback = False,
    wasm_browsers = ["blink", "gecko", "webkit"],
)

# JavaScript alone, for wider browser support:
flutter_web_bundle(
    name = "my_app_web_js",
    application = ":app",
    compiler = "dart2js",
    renderer = "canvaskit",
)
```

</details>

#### Content-Security-Policy

A `<meta http-equiv="Content-Security-Policy">` in `web/index.html` applies both to the built bundle and to the dev loop (`flutter_bazel run -d chrome`), because the dev loop serves the same page. Measured on `e2e/web_example` with Flutter 3.47:

| Policy | Built bundle (WASM) | Dev loop (DDC) |
|---|---|---|
| `script-src 'self' 'wasm-unsafe-eval'` | Renders | Blank page |
| `script-src 'self' 'unsafe-inline' 'wasm-unsafe-eval'` | Renders | Renders |

The dev loop needs `'unsafe-inline'`. Adding `'unsafe-eval'` instead changes nothing. The failure is silent: DWDS connects, the VM service answers, every module loads, no CSP violation reaches the console, and the app never paints. `connect-src 'self' ws: wss:` is enough for the dev loop's WebSocket.

A bundle served under `default-src 'self'` or `script-src 'self'` must also serve its own renderer, with `use_local_canvaskit = True`. Otherwise the engine's import of `skwasm.js` from `www.gstatic.com` is blocked, the loader rejects, and the page shows the bootstrap's "could not start" message instead of the app. Flutter's font fallback from `fonts.gstatic.com` is blocked too, which is harmless unless the app needs those glyphs.

A page that is also cross-origin isolated (see below) needs `worker-src 'self' blob:` beside that policy. Multi-threaded skwasm starts its worker from a `blob:` URL, a policy with `script-src 'self'` and no `worker-src` refuses it, and the page stays blank with nothing in the way of a message (measured in Chrome 156 with a local renderer: blank without the `worker-src`, rendered with it).

So a policy strict enough to be useful cannot live in `web/index.html` today, because the dev loop reads the same file. If you need one, compose `flutter_web_bundle` directly with a generated `index_html` for the production bundle.

#### Cross-origin isolation

skwasm runs its renderer on threads only in a cross-origin-isolated page, which needs two response headers: `Cross-Origin-Opener-Policy: same-origin` and a `Cross-Origin-Embedder-Policy`. `flutter_bazel run --wasm` sends both, and so must whatever serves the deployed bundle. The embedder policy is the app's choice, set once on the target:

The default renderer, fetched from `www.gstatic.com`, works in an isolated page and runs multi-threaded: the CDN answers with `Access-Control-Allow-Origin: *` and `Cross-Origin-Resource-Policy: cross-origin`, and skwasm's worker is a same-origin `blob:` that imports the CDN script as a module. Measured under `require-corp` in Chrome 156 and Safari 27, release builds: the app rendered and a worker started with the CDN renderer and with `use_local_canvaskit`, and without isolation neither starts a worker and the loader warns that skwasm runs single-threaded. So `use_local_canvaskit` is for air-gapped hosts and strict policies, not for threading.

```starlark
flutter_web_app(
    name = "app_web",
    application = ":app",
    cross_origin_embedder_policy = "credentialless",  # default "require-corp"
)
```

- **`require-corp`** (the default) isolates the page in every browser. It blocks a cross-origin subresource, such as an image from a CDN, unless that response carries a `Cross-Origin-Resource-Policy` header or is fetched with CORS. Flutter's own load of the skwasm renderer from `www.gstatic.com` passes.
- **`credentialless`** loads such subresources without cookies instead of blocking them. Chrome and Firefox isolate the page under it; Safari does not, so skwasm runs single-threaded there. Upstream `flutter run` always sends this one.

The dev tool reads the value from `<bundle>.serving.json`, which the build writes beside the bundle directory rather than inside it, so it is not deployed. `--no-cross-origin-isolation` turns both headers off for a run, and `--web-header` can then set your own.

### Cross-compiling

`gen_snapshot`, the AOT compiler, runs on the host and produces code for the target. Flutter publishes a different binary per host and target pair, and not every pair exists.

| Host | Target | AOT (release) | JIT (debug) | Notes |
|---|---|:---:|:---:|---|
| macOS | macOS | Yes | Yes | Native build |
| macOS | iOS | Yes | Yes | `rules_apple` handles the transition |
| macOS | Android | Yes | Yes | The Android rules handle the transition |
| macOS | Linux | No | Yes | Needs an LLVM cross-toolchain |
| macOS | Windows | No | Yes | Needs a Windows cross-toolchain |
| macOS | Web | Yes | n/a | Web uses dart2wasm or dart2js, not gen_snapshot |
| Linux | Linux | Yes | Yes | Native build |
| Linux | Android | Yes | Yes | The Android rules handle the transition |
| Linux | iOS | No | No | Needs Xcode |
| Linux | Web | Yes | n/a | |
| Windows | Windows | Yes | Yes | Native build |
| Windows | Android | Yes | Yes | The Android rules handle the transition |
| Windows | Web | Yes | n/a | |

The gap is desktop to desktop: there is no release cross-compile from macOS to Linux or Windows, because Flutter does not publish those `gen_snapshot` binaries. Build debug bundles across, or build release natively on the target.

### Release builds and permissions

`flutter create`'s scaffold grants network access in debug and profile builds only, and these rules reproduce that. An app that reaches the network under `-c dbg` can be offline under `-c opt` with no build error, no exception, and nothing in its log. The same shape exists on every platform, because in every case the debug-only grant is for the Dart VM service, not for the app:

| Platform | What debug has that release does not | Why |
|---|---|---|
| macOS | `com.apple.security.network.server` and `com.apple.security.cs.allow-jit` in `DebugProfile.entitlements`, which profile builds use too. `Release.entitlements` has only `app-sandbox`. | The sandbox must let the VM service bind and the JIT map executable pages. |
| Android | `android.permission.INTERNET`, from `android/app/src/debug/AndroidManifest.xml` (and `src/profile/` in profile builds). | Android enforces `INTERNET` at the kernel level. Without it the VM service cannot bind even a loopback socket. |
| iOS | `NSBonjourServices` and `NSLocalNetworkUsageDescription`, merged in by these rules for non-release builds. | The engine advertises the VM service over mDNS. |

An app that uses the network for itself has to say so once, in a way that applies to every compilation mode:

```starlark
flutter_macos_app(
    name = "my_app_macos",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_ios_app(
    name = "my_app_ios",
    application = ":my_app",
    bundle_id = "com.example.myapp",
    additional_entitlements = ["entitlements/Network.entitlements"],
)

flutter_android_app(
    name = "my_app_android",
    application = ":my_app",
    application_id = "com.example.myapp",
    permissions = ["android.permission.INTERNET"],
)
```

where `entitlements/Network.entitlements` is an ordinary plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
</dict>
</plist>
```

These attributes add to whichever base file the compilation mode selected, so one declaration covers debug and release, and the `flutter create` files stay untouched. A key the base already has with the same value is deduplicated, so declaring `network.server` above is safe even though `DebugProfile.entitlements` already grants it. A key the base has with a different value is an error naming the key and both files.

Note that `com.apple.security.network.client` is in neither scaffold file. Most Flutter apps go through `NSURLSession`, which the sandbox exempts. A raw socket is not exempt, so if you open one, you need this key.

**iOS local network privacy.** iOS 14 and later gate LAN access behind `NSLocalNetworkUsageDescription` and `NSBonjourServices`. The rules add both to non-release builds for the VM service and drop them in release. An app that needs LAN access for itself declares them in `ios/Runner/Info.plist`, where they survive into `-c opt`. The rules merge the VM service keys into that file, keeping your usage description and adding `_dartVmService._tcp` to your Bonjour list. The iOS simulator does not enforce local network privacy, so only a physical device tells you whether these keys are right.

**Check the artifact.** A `build_test` cannot see any of this. Read the built app:

```sh
# macOS: the entitlements codesign embedded
unzip -oq bazel-bin/my_app_macos.zip -d /tmp/app && \
  codesign -d --entitlements - "/tmp/app/My App.app"

# Android: the compiled manifest inside the APK
aapt2 dump xmltree --file AndroidManifest.xml bazel-bin/my_app_android.apk

# iOS: the processed Info.plist inside the .ipa
unzip -oq bazel-bin/my_app_ios.ipa -d /tmp/ipa && \
  plutil -p "/tmp/ipa/Payload/my_app_ios.app/Info.plist"
```

Remember that a plain `bazel build` is a release build, so it already takes the release side of each of these choices. `e2e/macos_example`, `e2e/android_example`, and `e2e/ios_example` each have a test that reads the built artifact this way.

## Custom engines and frameworks

By default an app builds against a Flutter release: its framework from the release's tag and its engine from the official artifacts. You can also build against a framework and an engine of your own, for example a flutter/flutter checkout and the engine you built in it, which is what `flutter run --local-engine` does upstream. Each such pairing is a named *SDK*, declared next to the release, and each build picks one.

### Building against a local checkout

Build the engine in the checkout as usual, with `engine/src/flutter/tools/gn` and `ninja`, then declare an SDK over it. The checkout's path is machine-local, so it never appears in `MODULE.bazel`:

```starlark
flutter = use_extension("@rules_flutter//flutter:extensions.bzl", "flutter")

# The release: what a build gets when it names no SDK.
flutter.toolchain(flutter_version = "3.47.9")

# The checkout's framework and engine, as the SDK named "local".
flutter.toolchain(
    name = "local",
    engine = "@flutter_local_engine",
    framework = "@flutter_local_framework",
)

local_framework = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_framework")
local_engine = use_repo_rule("@rules_flutter//flutter:local_sdk.bzl", "flutter_local_engine")

local_framework(name = "flutter_local_framework")

local_engine(name = "flutter_local_engine")
```

The repositories these rules make load `@rules_dart`, so the module that declares them has a `bazel_dep` on rules_dart.

The paths and the choice to use the SDK go in your untracked `.bazelrc.user`. `FLUTTER_CHECKOUT` is the flutter/flutter checkout. `FLUTTER_ENGINE` is the engine's source directory, which flutter_tools reads under the same name (it is the default of `--local-engine-src-path`): usually the checkout's `engine/src`, and the directory whose `out` holds the built out dirs. The engine is read from `FLUTTER_ENGINE` alone, never derived from `FLUTTER_CHECKOUT`, so an engine built elsewhere works with any checkout's framework.

```bazelrc
common --repo_env=FLUTTER_CHECKOUT=/Users/me/src/flutter
common --repo_env=FLUTTER_ENGINE=/Users/me/src/flutter/engine/src
common --@rules_flutter//flutter:sdk=local
```

`flutter_local_framework` links the checkout's `packages/` and `bin/internal/`, so an edit to the framework is seen by the next build. `flutter_local_engine` scans `$FLUTTER_ENGINE/out`, takes the `sky_engine` package from the host debug out dir's `gen/dart-pkg/sky_engine` (as flutter_tools does), reads each out dir's `args.gn` to learn what it holds, and links in the files each piece of the engine needs. A ninja rebuild changes a linked file, and the next build picks it up.

Which out dir serves what, by the names `tools/gn` gives them (the CPU appears in a name only when it is not the platform's default, so an Apple silicon Mac's host build is `host_debug_arm64`):

| Out dir | Serves |
|---|---|
| `host_debug[_unopt][_<cpu>]` | The host tools (the Dart SDK, `frontend_server`, `flutter_tester`, `impellerc`, ...) and the debug platform kernel; on a Mac, the debug macOS engine |
| `host_profile...`, `host_release...` | That mode's macOS engine and `gen_snapshot` on a Mac, or that mode's Linux or Windows engine on those machines; `host_release` also gives the release platform kernel |
| `ios_debug_sim[_unopt][_<cpu>]` | The iOS simulator engine, which is what debug means for iOS |
| `ios_profile...`, `ios_release...` | The iOS device engine and its `gen_snapshot` |
| `android_<mode>[_unopt][_<cpu>]` | The Android engine (`flutter.jar`) and, for profile and release, its `gen_snapshot` |
| `linux_<mode>[_<cpu>]`, `win_<mode>[_<cpu>]` | A Linux or Windows engine built for a machine other than this one, for debug cross-builds |
| `wasm_release` | The web SDK (`flutter_web_sdk/`, with `canvaskit/`) |

Build only the out dirs your builds need. A `-c dbg` macOS app needs `host_debug_<cpu>`; a release one needs `host_release_<cpu>` too.

If two out dirs fit the same slot (`host_debug_arm64` and `host_debug_unopt_arm64`, say), the build fails and lists them. Choose with `--repo_env=FLUTTER_LOCAL_ENGINES=host_debug_unopt_arm64,host_release_arm64`.

The engine source directory also needs its Dart source, `flutter/third_party/dart`, which `gclient sync` fetches. rules_dart compiles each library's dependents against an outline of it (its kernel without function bodies), so an edit inside a function body does not recompile them. The tool that makes outlines reads only the kernel format of the Dart it ships with, so an engine built from a checkout is built from that checkout's own `pkg/kernel`. Without the source, a build fails saying so and naming the two ways out: run `gclient sync`, or build with `--@rules_dart//dart:outline_kernel=false`.

Programs built with a custom SDK get its own `FLUTTER_VERSION`, `FLUTTER_FRAMEWORK_REVISION`, `FLUTTER_ENGINE_REVISION` and `FLUTTER_DART_VERSION` defines, from the checkout's version and commit and the engine's `args.gn`. `flutter_test` runs under the selected SDK too: its modules compile against the checkout's platform kernel.

You can also replace only one half. Give `flutter.toolchain` just `engine` or just `framework`, with `flutter_version` naming the release that supplies the other half. A framework whose `bin/internal/material_fonts.version` names a fonts revision no pinned release uses needs `material_fonts_sha256`.

### Choosing the SDK per build

`--@rules_flutter//flutter:sdk=<name>` picks the SDK. Leave it out and you get the release, which is named `flutter`. Put the flag in `.bazelrc.user` to make the checkout your default on one machine, or pass it on the command line for one build:

```sh
bazel build //:app --@rules_flutter//flutter:sdk=local
```

Each SDK's repositories are fetched only when a build selects it. Without `FLUTTER_CHECKOUT` and `FLUTTER_ENGINE` set, the repositories still load, so `bazel query` works on a machine with no checkout, and a build that selects the SDK fails at analysis with the `.bazelrc.user` lines to add. A name no `flutter.toolchain()` declares fails, listing the ones that are declared. An SDK other than `flutter` can only be declared in the root module.

All SDKs share one `pubspec.lock`. The `sdk: flutter` packages (`flutter`, `flutter_test`, ...) come from the selected SDK's framework. If what the checkout's pubspecs ask of a hosted package does not match the lock, or the lock needs a newer Flutter than the checkout is, the build fails naming each package and gives the command that re-resolves against that SDK:

```sh
bazel run --@rules_flutter//flutter:sdk=local @rules_flutter//flutter/pub -- get
```

### What the app records

An app built with a custom SDK carries `flutter_sdk.json` beside its Flutter assets: in `App.framework/Resources/flutter_assets/` on macOS, `flutter_assets/` in iOS's `App.framework/`, `assets/flutter_assets/` in an APK, `data/flutter_assets/` in a Linux or Windows bundle, and `assets/` on the web. An app built with the release carries none, so release apps are unchanged.

```json
{
  "engine": {
    "<engine repository>//host/darwin-arm64:tools": {
      "as_of": "gn",
      "content_hash": "...",
      "dart_version": "...",
      "engine_version": "4f1c...",
      "origin": "out_dir",
      "out_dir": "host_debug_arm64"
    },
    "<engine repository>//macos/release:engine": { "out_dir": "host_release_arm64", "...": "..." }
  },
  "framework": {
    "commit": "4f1c...",
    "dirty": true,
    "origin": "local",
    "version": "3.50.0-1.0.pre-210"
  },
  "kernel": {"format": 138, "sdk_hash": "0000000000"},
  "sdk": "local",
  "snapshot_hash": "0451907c2eaa8467e848c0067bfe8ed4"
}
```

- `framework` is the checkout: its version (from `bin/cache/flutter.version.json`, or `git describe --tags` without one), its commit, and whether it had uncommitted changes when the build read it.
- `engine` has one entry for each piece the app was built from, keyed by the piece's label: the host tools, the platform kernel, the engine and, in profile and release, the `gen_snapshot`. `engine_version`, `content_hash` and `dart_version` are what `tools/gn` wrote into the out dir's `args.gn`. `as_of: "gn"` says so: that commit is the one checked out when `tools/gn` generated the directory, which can be older than the last `ninja` run.
- `snapshot_hash` and `kernel` are the fingerprints the engine's Dart VM checks; see below. A web app has no `snapshot_hash`.
- The record holds no path of the machine that built the app: the checkout's path and every absolute path are left out.

### What fails, and how

Every failure names what is missing or which artifacts disagree, and how to fix it.

**A piece the out dirs do not have.** A build that needs an engine for a mode, platform or CPU the out dirs lack fails at analysis. The message names the piece, the out dirs it found, and the `tools/gn` and `ninja` commands that build the missing one. A mode is never served by another mode's engine: a debug engine cannot run AOT code, and a release engine rejects anything not compiled for release. Builds that do not need the missing piece are unaffected, so a checkout with only `host_debug_arm64` and its Dart source builds every `-c dbg` macOS app on an Apple silicon Mac.

**An engine of the wrong CPU.** A locally built engine holds one CPU, where the release's macOS engine is universal. An app built for a CPU the engine lacks fails at analysis naming the engine, what it contains and what the build is for. An iOS app checks the same way for the device or simulator slice it needs, and an Android app for each ABI it carries.

**Pieces built from different Darts.** Once per SDK, platform and mode, one action, `FlutterSdkCheck`, reads the fingerprints out of the artifacts, and every app of that combination depends on it, so it cannot be skipped. It fails the build when:

- the engine's platform kernel and the Dart SDK's `vm_platform_strong.dill` have different kernel formats or SDK hashes;
- in profile and release, `gen_snapshot` and the engine binary share no snapshot hash (the engine's VM refuses a snapshot whose hash is not its own);
- the Dart SDK's `dartaotruntime` is of another Dart than the engine.

For example:

```
The Flutter SDK does not match itself for release:
  gen_snapshot  <engine repository>//macos-arm64/release:gen_snapshot_darwin-arm64
                (.../macos-arm64/release/gen_snapshot)
                snapshot hash 9f3c...
  engine        <engine repository>//macos/release:engine
                (.../macos/release/FlutterMacOS.framework/Versions/A/FlutterMacOS)
                snapshot hash 0451...
An engine only runs code compiled by a gen_snapshot from the same Dart. Rebuild both from one checkout.
```

A web SDK has no engine binary or `gen_snapshot`, so a web build checks only the kernel: each of the web SDK's platform dills against the Dart SDK. A web app of a custom engine loads its renderer from the web SDK rather than the CDN, which has nothing for an engine that is not a release, so a web SDK without `canvaskit/` fails too.

**A checkout that is not one.** A `FLUTTER_CHECKOUT` without `packages/flutter/pubspec.yaml`, or a `FLUTTER_ENGINE` without `out`, fails when the repository is fetched, naming what is missing.

### Writing an engine source

`flutter_local_engine` is one *engine source*. Any repository that follows the same contract can be one, and `flutter.toolchain(engine = "@my_engine")` uses it the same way. The release's engine is written to this contract too.

An engine source has a `flutter_engine.json` at its root and a target, a *slice*, at each of these labels. `<host>` is the machine the tools run on (`darwin-arm64`, `darwin-x64`, `linux-x64`, `linux-arm64`, `windows-x64`); `<mode>` is `debug`, `profile` or `release`.

| Label | Rule (provider) | Used by |
|---|---|---|
| `//:flutter_engine.json` | a file | `{"origin": ..., "description": ...}`, plus `engine_revision` and `dart_version` for the `FLUTTER_*` defines |
| `//host/<host>:tools` | `flutter_host_tools` (`FlutterHostToolsInfo`) | every build whose actions run on `<host>` |
| `//kernel/debug:platform` | `flutter_platform_kernel` (`FlutterPlatformKernelInfo`) | debug and profile Dart compiles |
| `//kernel/release:platform` | `flutter_platform_kernel` | release Dart compiles |
| `//sky_engine:pubspec.yaml` | a file: the `pubspec.yaml` of the engine's `sky_engine` package, the rest of the package beside it | resolving `pubspec.lock` against a framework source (`@rules_flutter//flutter/pub`) |
| `//outline_tool:outline_tool` | the outline tool, for example an `alias` to the `:outline_tool` of a rules_dart `dart_kernel_source(path = ...)` of the engine's Dart | builds with `--@rules_dart//dart:outline_kernel` (the default) |
| `//macos/<mode>:engine` | `flutter_macos_engine_slice` (`FlutterEngineInfo`) | macOS apps |
| `//macos/<mode>:xcframework` | `flutter_macos_engine_slice`, its files a whole `FlutterMacOS.xcframework` | macOS add-to-app (`flutter_macos_xcframeworks`) |
| `//ios/<mode>:engine` | `flutter_ios_engine_slice` | iOS apps; `debug` is the simulator engine |
| `//android-<arch>/<mode>:engine` | `flutter_android_engine_slice` | Android apps; `<arch>` is `arm`, `arm64` or `x64` |
| `//linux-<arch>/<mode>:engine` | `flutter_linux_engine_slice` | Linux apps; `<arch>` is `x64` or `arm64` |
| `//windows-x64/<mode>:engine` | `flutter_windows_engine_slice` | Windows apps |
| `//<target>/<mode>:gen_snapshot_<host>` | `flutter_gen_snapshot` (`FlutterGenSnapshotInfo`) | profile and release builds for `<target>` (`macos-<arch>`, `ios-arm64`, `android-<arch>`, `linux-<arch>`, `windows-x64`) run on `<host>` |
| `//web:sdk` | `flutter_web_sdk` (`FlutterWebSdkInfo`) | web apps, with the files a web app names beside it in `//web` (`files`, `dart2js_platform.dill`, `dart2wasm_platform.dill`, `ddc_outline.dill`, `libraries.json`, `ddc_dart_sdk.js`, `ddc_module_loader.js`, `dart_stack_trace_mapper.js`) |

The rules and providers load from `@rules_flutter//flutter:engine.bzl`, whose docstrings list every field. A slice can be anything that returns the provider: one of these rules over downloaded files, over symlinks into a build directory, an `alias` into another repository, or a target that builds the files. Every provider takes a `provenance` dict, which is what the app's record shows for that piece. Keep machine paths out of it: the record drops a `path` key and any value starting with `/`, and nothing else.

Define every label, and make the ones you do not provide `flutter_missing_slice`s. A build that needs one fails at analysis with your message, and a build that does not is unaffected:

```starlark
load("@rules_flutter//flutter:engine.bzl", "flutter_macos_engine_slice", "flutter_missing_slice")

# macos/release/BUILD.bazel
filegroup(
    name = "files",
    srcs = glob(["FlutterMacOS.framework/**"]),
)

flutter_macos_engine_slice(
    name = "engine",
    mode = "release",
    cpus = ["arm64"],
    files = ":files",
    binary = ":FlutterMacOS.framework/Versions/A/FlutterMacOS",
    provenance = {"origin": "my_build", "commit": "4f1c..."},
    visibility = ["//visibility:public"],
)
```

```starlark
# ios/release/BUILD.bazel
flutter_missing_slice(
    name = "engine",
    message = "This engine has no iOS build. Build iOS apps with the release.",
    visibility = ["//visibility:public"],
)
```

`cpus` is what the CPU check reads, `binary` is the file whose snapshot hash the check reads (for Android, `flutter.jar` with `binary_entry = "lib/<abi>/libflutter.so"`), and an iOS slice lists its `xcframework_slices`. The same `FlutterSdkCheck` runs on your pieces as on a checkout's.

A *framework source* is the other half: a repository whose root is a flutter/flutter tree, with `packages/`, `bin/internal/material_fonts.version`, and a `flutter_framework.json` saying what it is: `{"version": "...", "commit": "...", "dirty": false, "origin": "..."}`.

### Limitations

- `flutter_local_engine` is tested against a stand-in checkout: `e2e/custom_engine` lays the official release's artifacts out the way a checkout's out dirs hold them, with matching `args.gn` files. The out dir layout and `args.gn` fields it reads follow `tools/gn`, but have not yet been checked against a real engine build.
- A debug iOS build is a simulator build. There is no debug build for an iOS device from out dirs.
- Engines and `gen_snapshot`s for macOS and iOS are read only on a Mac.
- A desktop profile or release build uses the out dir's own `gen_snapshot`, which runs only on the machine it was built for, so those builds exist only for the machine's own platform. As with the release, release builds for another desktop OS do not cross-compile; debug builds do.
- The only engine and framework sources rules_flutter ships are the release and a local checkout. Anything else, such as a fork's artifacts at a URL, needs a repository you write to the contract above.

## Rules reference

The core rules load from `@rules_flutter//flutter:defs.bzl`.

### flutter_library

Collects Dart sources and assets for a Flutter package. It does not compile anything. It carries `DartInfo` and `FlutterInfo` to whatever depends on it.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_lib",
)

flutter_library(
    name = "my_lib",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:some_package"],
    assets = glob(["assets/**"]),
    package = ":pubspec-metadata",
)
```

| Attribute | Description |
|---|---|
| `srcs` | Dart source files. Required. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `assets` | Asset files: images, fonts, and so on, from anywhere in the Dart package. Bundled at `packages/<package_name>/<path>` in a program of another package and at `<path>` in a program of this package (its own `flutter_test`, or the application this is part of), as `flutter build` keys them. The path is the file's path from the package root, the directory above `lib/`, so a file listed here is one of the package's: to bundle a file from elsewhere (another package, or a generated file) at a path of this package, put it at that path with a rule of this package, such as `copy_file`, and list that. |
| `fonts` | The package's font families, `flutter_font_family` targets, as `flutter: fonts:` in `pubspec.yaml` declares them (see [Fonts](#fonts)). A program of another package sees each family as `packages/<package_name>/<family>`, and each font at `packages/<package_name>/<path>`; a program of this package sees both bare, as `flutter build` keys them. |
| `shaders` | The package's fragment shaders, mirroring `flutter: shaders:` in `pubspec.yaml`, keyed by their path from the package root as `assets` are. Bundled at `packages/<package_name>/<path>` in a program of another package and at `<path>` in a program of this package (its own `flutter_test`, or the application this is part of), as `flutter build` keys them, where `FragmentProgram.fromAsset` looks for them. |
| `shader_includes` | Files the `shaders` may `#include`, such as `glob(["shaders/**/*.glsl"])`. A shader compiles with only its declared inputs, so an include not listed here is not found. |
| `package` | The package's `dart_package_metadata`, `:pubspec-metadata` in the BUILD file at the package root, which states its name, its language version (the `sdk:` constraint in `pubspec.yaml`), its version, its licence and its hooks. Its directory is the package root, and `srcs` and `resources` must be under that root's `lib/`. Without it, the package is named for its root directory and states nothing else. |

#### Fonts

A font family is a target, as an entry of `flutter: fonts:` is, and each of its fonts a file or a `flutter_font` with the entry's `weight` and `style`:

```starlark
flutter_font(
    name = "inter_bold",
    src = "fonts/Inter-Bold.ttf",
    weight = 700,  # 100 to 900; style = "italic" or "normal"
)

flutter_font_family(
    name = "inter",
    family = "Inter",
    fonts = [
        "fonts/Inter-Regular.ttf",  # no weight, no style
        ":inter_bold",
    ],
)

flutter_library(
    name = "ui",
    srcs = glob(["lib/**/*.dart"]),
    fonts = [":inter"],
    package = ":pubspec-metadata",
)
```

| Rule | Attribute | Description |
|---|---|---|
| `flutter_font_family` | `family` | The family name, which `TextStyle.fontFamily` selects. Defaults to the target's name. |
| | `fonts` | Its fonts, in order: `flutter_font` targets, or font files, each a font with no weight and no style. |
| `flutter_font` | `src` | The font file. Required. |
| | `weight` | `100` to `900`, in steps of 100. Unset, the font has none. |
| | `style` | `normal` or `italic`. Unset, the font has none. |
| | `asset` | For a font of another package, the `packages/<package>/<path>` a pubspec names it by: every program bundles `src` at that path. |

A font is a file of the package whose `flutter_library` or `flutter_plugin` lists the family, keyed by its path from the package root, as an asset is; a file outside it fails the build unless `asset` names it as another package's.

**Fonts fetched at run time.** `package:google_fonts` downloads fonts over the network when the app first draws them. In a `flutter_test`, whose test binding answers every HTTP request with an error, a widget drawing such a font fails, and an app offline falls back to another font. To ship the fonts instead, list their `.ttf` files (`Lato-Regular.ttf`, as Google Fonts names them) in a `flutter_library`'s `assets`, where `google_fonts` finds them by file name in the asset manifest, and set `GoogleFonts.config.allowRuntimeFetching = false` before `runApp`.

### flutter_application

Compiles a Flutter app. In debug mode (`-c dbg`) it produces a kernel `.dill` for the JIT. Otherwise it produces AOT native code. Either way it also builds the `flutter_assets/` bundle. The platform macros consume its `FlutterApplicationInfo`, except the web app's, which compiles the application's program itself with the web compilers (see [Web](#web)).

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = [
        ":my_lib",
        "@deps//:flutter",
        "@rules_flutter//flutter:material_icons",
    ],
    native_deps = [":my_native_lib"],
)
```

| Attribute | Description |
|---|---|
| `main` | The entry point. Required. It can sit outside the package's `lib/`, as `flutter run -t` allows: `test_driver/app.dart`, say. See [Hot reload and hot restart](#hot-reload-and-hot-restart). |
| `package` | The app's `dart_package_metadata`. Required. Its `package_name` is the same as `pubspec.yaml`'s `name:`; it keys the compiled libraries under stable `package:` URIs, which hot reload matches against, and resolves `package:<self>/...` imports. |
| `srcs` | Other Dart sources in the app package, including generated ones. List here any file a `main` outside `lib/` imports by relative path. |
| `deps` | `dart_library` or `flutter_library` targets. Add `@rules_flutter//flutter:material_icons` to bundle the Material icon font. |
| `assets` | Asset files for the bundle, each under its path in the application's Bazel package (`assets/a.png`), wherever in the workspace that package is. That is the key `rootBundle` and `Image.asset` load it by, and the one `flutter run` gives it. A file from another package fails the build. |
| `native_deps` | Shared libraries to bundle for `dart:ffi`. A web app built over the application bundles none, as `flutter build web` builds no native code. |
| `defines` | Dart environment defines, the `-D` flags. |
| `obfuscate` | Obfuscate Dart symbols in the AOT output. Pair with `split_debug_info`. Default `False`. |
| `split_debug_info` | Write debug info to a separate `.symbols` file. Default `False`. |
| `extra_gen_snapshot_options` | Extra flags for `gen_snapshot`. `--no-strip` keeps the shipped binary's local symbols, as it does in `flutter build`; it is not passed on to `gen_snapshot`. A flag that makes `gen_snapshot` write a file (`--save-obfuscation-map`, `--write-v8-snapshot-profile-to`, `--print-instructions-sizes-to`) names it relative to the package, as `--save-obfuscation-map=obfuscation.json`. The file is built to `<name>_gen_snapshot/obfuscation.json`, and it is in the target's `gen_snapshot_files` output group. |
| `track_widget_creation` | Record where each widget was created, for the DevTools inspector, as `flutter run` does. Debug and profile builds; a release build never does. Default `True`. |
| `shaders` | Fragment shaders to compile with impellerc. |
| `shader_includes` | Files the `shaders` may `#include`. |
| `require_sksl_shaders` | Fail the build when a shader cannot be compiled for Skia (SkSL). By default such a shader, say one that indexes a uniform array in a loop, is compiled for Impeller alone with a warning, as `flutter build` does, and fails to load only where the app renders with Skia. Web builds always need SkSL. Default `False`. |
| `tree_shake_icons` | Keep only the icon glyphs the app uses, in a release or profile build. Default `True`. It needs every `IconData` to be constant, and an icon font family of one font file; as with `flutter build`, a non-constant `IconData`, a family of several font files that the app draws icons from, or a `const_finder` or `font-subset` that fails fails the build. Set `False` to ship the fonts whole. |
| `link_hook_assets` | The data assets packages' link hooks emit, each `package:<package>/<name>`. See [Link hooks](#link-hooks). |
| `additional_licenses` | The files the pubspec's `flutter: licenses:` lists. They are appended to `NOTICES.Z` as they are, after the sorted entries. |
| `minimum_os_version` | Minimum Apple deployment target, passed to `gen_snapshot` as `--macho-min-os-version`. |

**Licences.** The program's own licence is the `license_file` of its `dart_package_metadata`, the `NOTICES` or `LICENSE` file at the root of its package. `NOTICES.Z` (`NOTICES` on the web) lists it under the package name, with the licence of every package in `deps` (each package states its own: a package of your workspace as the `license_file` of its `dart_package_metadata`) and the Flutter engine's, which every program ships.

**Defines from the command line.** The repeatable flag `--@rules_dart//dart:extra_dart_defines=KEY=VALUE` adds a define to every Dart compile: native kernel, `flutter_test`, dart2wasm, and dart2js. It is rules_dart's flag, so the `dart_test` and `dart_binary` targets of the same build take the same defines; build tools in the exec configuration are compiled without them. Each occurrence of the flag is one define, so values may contain commas, except in a `flutter_test`: its dependencies are compiled one library at a time by the SDK's `kernel_worker`, which splits every value on commas, so a comma there is refused at analysis. When a key is set both by the flag and by the `defines` attribute, the flag wins. The keys the Flutter build sets itself (`dart.vm.profile` and `dart.vm.product` from the compilation mode, `FLUTTER_APP_FLAVOR` from `flavor`, `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` from `build_name` and `build_number`, the `FlutterVersion` ones, and `flutter.dart_plugin_registrant`) are refused, in the flag and in `defines`, when a Flutter target is built. The dev tool's `--dart-define` forwards to this flag and replays the defines on hot reload and restart, matching `flutter run --dart-define`.

### flutter_application_variant

The same application with another `main`. It compiles the application's program again with `main` as the entry point, adds `srcs`, `deps` and `defines` to the application's, and keeps the rest (the application's own `main` stays a source, for the new one to import): its Dart package (so `package:my_app/...` imports in the new `main` resolve), assets, native libraries, shaders and build options. It returns what `flutter_application` returns, so every platform rule takes it as its `application`. The framework and each package are compiled once for the variant and the application alike.

It is exported from `@rules_flutter//flutter:integration_test.bzl`, beside the rules that run integration tests, but it is not tied to them: an entry point of its own, as `flutter run -t test_driver/app.dart` runs, is the same shape.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_application_variant")

flutter_application_variant(
    name = "driver_flutter",
    application = ":my_app",
    main = "test_driver/app.dart",
    srcs = ["test_driver/banner.dart"],
)

flutter_macos_app(
    name = "driver_app",
    application = ":driver_flutter",
    bundle_id = "com.example.myapp.driver",
)
```

| Attribute | Description |
|---|---|
| `application` | The `flutter_application` to rebuild. Required. It may be in another Bazel package: the variant is in the application's Dart package and its assets keep their keys there. |
| `main` | The entry point, in place of the application's. Required. It may sit outside the package's `lib/`. |
| `srcs`, `deps`, `defines` | Added to the application's. A plugin only the variant's `deps` bring is registered in the variant and not in the application. |
| `unchecked_srcs` | Sources added like `srcs` whose imports are not checked against the program's `deps`: files a rule wrote for the program, whose imports are that rule's to get right. The integration test macros use it for the bootstrap and its support library. |
| `requires_packages` | Packages the program must have, by name. Analysis fails, naming the package and the `@<hub>//:<package>` target to add, if no dependency brings one. |

### flutter_test

Compiles and runs widget and unit tests on the Dart VM with Flutter's test engine. Assertions are enabled.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_test(
    name = "widget_test",
    package = ":pubspec-metadata",
    main = "test/widget_test.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

It takes the compile attributes of `flutter_application` (`main`, `srcs`, `deps`, `defines`, `package`, `assets`, `shaders`) plus the usual `data` and `env`, and `include_tags` and `exclude_tags` (below). Values in `env` are literal; there is no `$(location)` expansion.

A test of an app can name the app's `flutter_application` as `application` instead of repeating its package, as `flutter test` compiles a test in the package it is in. The application's package, sources, `deps`, `code_assets` and assets become the test's, so `package:my_app/…` resolves; the test's `main`, `srcs`, `deps` and `code_assets` add to them, and its `defines` and `flavor` are its own:

```starlark
flutter_test(
    name = "widget_test",
    application = ":my_app",
    main = "test/widget_test.dart",
    deps = ["@deps//:flutter_test"],
)
```

A test runs where its target runs, as a `cc_test` does: its `deps`, native code included, and the `flutter_tester` that runs it are built for the target platform, and Bazel's default test toolchain runs it on an execution platform matching that platform. On a Mac that is the Mac. To run tests on other machines, a Linux remote worker say:

- **`--platforms`** builds every test for that platform, so Bazel runs them on an execution platform matching it.
- **A platform transition** does the same for one test: wrap it in `platform_transition_test` from `@bazel_lib//lib:transitions.bzl` with `target_platform` set, and tag the wrapped `flutter_test` `manual`. `e2e/codegen`'s `:transitioned_native_asset_test` is one.
- **`exec_group_compatible_with = {"test": [...]}`** narrows the execution platforms a test may run on, and execution-requirement tags such as `no-remote-exec` keep it local. A test whose result depends on the machine, such as a golden, and one that loads an FFI library from `data`, are pinned this way.
- **A toolchain for `@bazel_tools//tools/test:default_test_toolchain_type`** registered in your root module changes where every test rule's tests may run, `flutter_test` included, as it does for `cc_test`. A test sent to a machine other than the one it was built for fails when it starts there, as a `cc_test` does.

A widget built in a test records where it was built, as under `flutter test`'s `--track-widget-creation`. A `flutter_test` sets `--@rules_dart//dart:track_creation_locations` for itself and its `deps`, so every library's kernel module and the test's own compile agree on it.

`enable_impeller = True` renders with Impeller in `flutter_tester`, as `flutter test --enable-impeller` does, instead of software Skia. A test that draws a shader SkSL cannot compile needs it, and so does a golden meant to match an Impeller device. Shaders are compiled for `flutter_tester` either way, with the SkSL and Vulkan stages `flutter test` gives them.

A `flutter_test_config.dart` wraps the suite as it does under `flutter test`: its `testExecutable(FutureOr<void> Function() testMain)` is handed the suite and runs it, so setup shared by every test in a directory lives in one file. The config used is the nearest one walking up from `main`'s directory, and the walk ends after the directory holding `pubspec.yaml`. Bazel can see only the BUILD file's own package, so the walk also ends there; name a config above it with `test_config = "//path:flutter_test_config.dart"`. The config is compiled into the test like its `main`, and its imports come from the test's `deps`.

Bazel's test protocol applies, as it does to `dart_test`:

- **Time.** The target's `size` or `timeout` replaces `package:test`'s 30-second default, so a test with no `timeout:` of its own runs as long as Bazel lets the target run. A `timeout:` written on a test still applies, and `Timeout.factor` scales Bazel's limit.
- **`--test_filter`.** A regular expression matched against each test's full name, group names included, like `flutter test --name`. A target the filter matches nothing in passes, so `bazel test //... --test_filter=x` runs only what it names.
- **`shard_count`.** Splits the suite's tests into contiguous shares, one per shard.
- **Tags.** `@Tags` on the test library, and `tags:` on a `test`, select cases as under `flutter test --tags`. Per run: `bazel test //... --test_env=DART_TEST_TAGS=golden` (and `DART_TEST_EXCLUDE_TAGS`), comma-separated boolean selectors as `--tags` takes them. A target it matches nothing in passes, and nothing is rebuilt. Fixed: `include_tags` and `exclude_tags`, the keys of `dart_test.yaml`, one selector per entry; a target whose fixed selection matches nothing fails. Both apply together. These are `package:test` tags: Bazel's `tags` and `--test_tag_filters` choose targets, not cases. `dart_test.yaml` itself is not read: its `include_tags` and `exclude_tags` become the attributes, and its per-tag settings (`tags:` with `skip` or `timeout`), `add_tags` and presets do not apply.
- **Library annotations.** `@Skip`, `@Timeout`, `@TestOn` and `@OnPlatform` on the test library apply as under `flutter test`: `@Timeout` merges with the target's timeout, and a suite its `@TestOn` excludes passes with a note in the log. `@TestOn` and `@OnPlatform` are evaluated against runtime `vm` on the host's operating system, as `flutter test` does for every suite whatever the device, so an integration test on a browser or a phone is still `vm` on the host.
- **No tests.** A suite that registers no test fails, as under `flutter test`; one whose every test is `testOn` another platform registers none here too.
- **Results.** Each case is reported in the `test.xml` Bazel collects, so CI shows cases rather than one pass or fail per target.
- **Coverage.** `bazel coverage --combined_report=lcov //...` collects the lines each `flutter_test` runs, as `flutter test --coverage` does, and Bazel merges them into one LCOV report (`$(bazel info output_path)/_coverage/_coverage_report.dat`; each test's own is `bazel-testlogs/<package>/<name>/coverage.dat`). It reports the `srcs` of the test and of every `flutter_library`, `dart_library` and `application` the test reaches, for the libraries `--instrumentation_filter` selects (by default those in the packages named on the command line), each file under its path in the workspace. The test's `main` is not reported, as for every Bazel test. Lines only: no function or branch counts.

#### Golden files

Goldens must be listed in `data`, or the test cannot see them:

```starlark
flutter_test(
    name = "widget_test",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)
```

This is the first thing to check when a golden fails, because the failure message does not say it. The comparator reads goldens from runfiles, so a PNG in the source tree that is not an input of the test is invisible to it, and it fails with `Could not be compared against non-existent file`, the same message you get when the file really is absent. If you can see the file on disk and the test says it does not exist, it is almost certainly undeclared. Making declared inputs the only inputs is what keeps a cached pass meaningful.

Otherwise `matchesGoldenFile('goldens/x.png')` means what it means under `flutter test`: the golden is read from `goldens/x.png` next to the test's `main`, and a mismatch reports the pixel difference the same way. When a comparison fails, the four diff images (`masterImage`, `testImage`, `isolatedDiff`, `maskedDiff`) are written under `bazel-testlogs/<pkg>/<target>/test.outputs/failures/`, and the failure message names the path. Upstream writes them beside the test, which under Bazel would be inside the sandbox and gone before you could open them.

To regenerate goldens, use upstream's flag under `bazel run`:

```sh
bazel run //:widget_test -- --update-goldens
```

That writes the PNGs into the source tree next to the test and names each one. The same flag under `bazel test` exits with code 64, because a test action cannot write to the source tree and a golden regenerated into the sandbox would report success while changing nothing. There is no repo-wide command; it is one `bazel run` per target, which `bazel query 'tests(//...)'` can drive.

Two limits come from Flutter rather than from these rules:

- **Goldens are host-specific.** Font rendering and antialiasing differ between operating systems, so a PNG generated on macOS may not match on Linux or Windows. Regenerate on the platform that checks them, or keep per-OS golden directories.
- **Replacing the comparator disables regeneration.** If a test assigns its own `goldenFileComparator`, `--update-goldens` calls that object's `update()`, which for `LocalFileComparator` writes into runfiles. The run passes, prints nothing, and leaves the source PNG unchanged.

### flutter_suite_program and flutter_program_test

`flutter_test` is a macro over two rules. `flutter_suite_program` compiles the test and returns a `FlutterTestProgramInfo` (below); `flutter_program_test` runs any target that returns one. `flutter_test(name = "x", ...)` declares a `flutter_suite_program` named `x.program` and the test `x`, so everything above holds as before: the attributes of both rules are `flutter_test`'s, a compile attribute (`main`, `srcs`, `deps`, `package`, `application`, `flavor`, `enable_impeller`, `test_config`, ...) goes to the program, a run attribute (`include_tags`, `exclude_tags`, `env`, `size`, `timeout`, `shard_count`, `args`) to the test, and `data`, `tags`, `visibility` and the platform constraints to both. The test's kind is `flutter_test` whichever way it is declared, so `bazel query 'kind(flutter_test, //...)'` lists every test and nothing else. The program is a target of its own, of kind `flutter_suite_program`.

Use the two rules directly to run a program that something else compiled, with everything `flutter_test` gives a test: the `bazel test` result protocol, `@Tags` selection (`include_tags`, `exclude_tags`, `DART_TEST_TAGS`), JUnit output, golden comparison and `--update-goldens`, code assets, sharding and coverage:

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_program_test", "flutter_suite_program")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_suite_program(
    name = "widget_program",
    testonly = True,
    package = ":pubspec-metadata",
    main = "test/widget_test.dart",
    data = glob(["test/goldens/**"]),
    deps = ["@deps//:flutter", "@deps//:flutter_test"],
)

flutter_program_test(
    name = "widget_test",
    program = ":widget_program",
    exclude_tags = ["slow"],
    shard_count = 2,
)
```

`flutter_suite_program` takes the compile attributes of `flutter_test` (and `data`, which its runfiles carry) and builds, but does not run, the kernel, the `flutter_assets` tree, the code assets and the Native Assets manifest. Mark it `testonly`, as `flutter_test` does. `flutter_program_test` takes `program`, `data`, `env`, `include_tags`, `exclude_tags` and the usual test attributes.

A rule that compiles tests its own way returns `FlutterTestProgramInfo` and `flutter_program_test` runs it. The program must be a kernel whose entry point speaks the `package:test_api` `RemoteListener` protocol over the WebSocket at `FLUTTER_TEST_HARNESS_PORT`, as the bootstrap `flutter_suite_program` generates does, and its `source` is the library the runner reads `@Tags` from. The golden-file comparator is installed by that bootstrap, so a program from another compile has to install one for `matchesGoldenFile` to compare anything.

### flutter_tester_binary

Runs a program under `flutter_tester`, the headless engine `flutter_test` uses, as an ordinary executable rather than a test. Use it to make build outputs with Flutter's rendering, such as store screenshots: the outputs do not have to be `testonly`. It is compiled as `flutter_test` compiles a test and takes the same attributes, `enable_impeller` included, except `include_tags` and `exclude_tags`: it is not a test, and `DART_TEST_TAGS` in a shell does not change it. A program that registers no test fails.

```starlark
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_tester_binary(
    name = "render",
    package = ":pubspec-metadata",
    main = "tool/render.dart",
    enable_impeller = True,
    deps = ["//:my_app_lib", "@deps//:flutter", "@deps//:flutter_test"],
)

genrule(
    name = "screenshot",
    outs = ["screenshot.png"],
    cmd = "OUT=$@ $(execpath :render)",
    tools = [":render"],
)
```

The program is written as a test suite, because `flutter_tester` draws frames through `package:flutter_test`'s binding: its work is the bodies of its `testWidgets` and `test` calls, and `tester.pumpWidget`, `tester.view` and `RenderRepaintBoundary.toImage` work as they do in a test. The binary exits 0 when every case passes and 1 when one fails, so a failed render fails the action. A case that runs past five minutes is stopped as wedged.

The program sees the environment it was started with and runs in the working directory it was started in, which for a build action is the exec root, so it can be handed paths of the action's inputs and outputs. Native Assets load from any working directory. Arguments are not passed to the program.

Build it for the machine it runs on. `bazel run` does that, and a rule that runs it in an action takes it as an executable attribute with `cfg = "exec"`, as `genrule` takes `tools`. With `enable_impeller = True` it needs that machine's GPU, so keep such an action off remote executors (`execution_requirements = {"no-remote-exec": "1"}`).

### Integration tests

`package:integration_test` tests run in the real app, on a device or in a browser, and each `testWidgets` is reported as a test case. The test is the `integration_test/app_test.dart` that `flutter create` users write, unchanged: `IntegrationTestWidgetsFlutterBinding.ensureInitialized()`, then `testWidgets` that call the app's own `main()`. The rules are in `@rules_flutter//flutter:integration_test.bzl`.

macOS, Windows, Linux, the web (headless Chrome), Android devices and the iOS simulator are the platforms so far; Windows is [below](#windows-integration-tests), Linux [after it](#linux-integration-tests), the web [next](#web-integration-tests), Android [after that](#android-integration-tests) and iOS [last](#ios-simulator-integration-tests).

```starlark
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata", "flutter_application")
load("@rules_flutter//flutter:integration_test.bzl", "flutter_macos_integration_test")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

flutter_application(
    name = "app_flutter",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = glob(["lib/**/*.dart"]),
    deps = ["@deps//:flutter"],
)

flutter_macos_integration_test(
    name = "app_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    bundle_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

`bazel test :app_test` builds the application with the test as its program, in debug mode whatever `-c` says (the suite is driven through the VM service a debug build serves, and `flutter test` forces debug for an integration test too), launches it on the host's own desktop, and drives the suite over that VM service, as `flutter test integration_test/app_test.dart -d macos` does. `integration_test` is in your `pubspec.yaml`'s `dev_dependencies`, as `sdk: flutter`. The app's own `main` is unchanged and carries no test code: the test is a program of its own, a variant of the application (see [flutter_application_variant](#flutter_application_variant)).

- **Per-test results.** Each test case is reported as it finishes, and the JUnit report names each one. `--test_filter` selects test cases by name, a regular expression matched against each full name, and `shard_count` divides them among shards.
- **Tags.** `@Tags` on `src` (the test file, which every integration test rule requires) and `tags:` on a `testWidgets` select cases as under `flutter test --tags`, on every platform: the host reads them, so an app that cannot be given an environment is selected the same way. Per run, `bazel test //... --test_env=DART_TEST_TAGS=golden` (and `DART_TEST_EXCLUDE_TAGS`); fixed, `include_tags` and `exclude_tags`, which work as for `flutter_test`, with a target whose fixed selection matches nothing failing and a run that narrows one to nothing passing. Bazel's `tags` choose targets, these choose cases.
- **Library annotations.** `@Skip`, `@Timeout`, `@TestOn` and `@OnPlatform` on `src` apply as for `flutter_test`, against runtime `vm` on the host's operating system whatever the device; a suite its `@TestOn` excludes passes without the app being launched.
- **A failing test fails the target**, and the JUnit report names the failing case. So does an app that exits during a test, with the reason the device gives: `The macOS app exited with code 3 …`. A suite that registers no test fails, since a program that declared nothing has not been tested.
- **One target per test file**, as `flutter test` launches the app once per file. `srcs` lists the files the test imports by relative path. A `flutter_test_config.dart` beside the test is found by the same search `flutter_test` runs, or is named with `test_config`. It runs in the app and, for goldens, on the host where they are compared, so a comparator or tolerance it installs applies; both compile it in the app's package, so it may import the app's libraries as `package:<app>/…`.
- **`deps` must bring `integration_test` and `flutter_test`**: analysis fails, naming the package and the `@<hub>//:<package>` target to add, if they are missing.
- **The test needs an unlocked, awake desktop.** The runner holds the display awake for the run and fails, saying which, if the screen is locked or the display is asleep. A test that cannot run is a failure, not a skip: a skipped test reads as a pass. Two tests do not share the screen at once, since a covered window stops drawing: they take turns on a lock (`/tmp/rules_flutter-locks/macos-gui.lock`), which the operating system releases if a test dies.
- **`env` reaches the runner and the app's process.** `data` is available to the test at run time.
- **Goldens work as in `flutter_test`**: `matchesGoldenFile('goldens/x.png')` reads `goldens/x.png` from the directory of `src`, so the goldens are `data` (`data = glob(["integration_test/goldens/**"])`). The picture is sent from the app to the host, which compares it with the same comparator `flutter_test` uses (a `flutter_tester` it starts for it), on every platform, an app on a phone or in a browser included. A mismatch fails the test, naming the golden and how far it is off, and leaves the pictures of the failure in the target's undeclared outputs (`bazel-testlogs/<target>/test.outputs/failures/`). `bazel run :app_test -- --update-goldens` writes the goldens into the source tree instead of comparing, naming each file it wrote. A golden is a function of the platform that rendered it: keep one per platform (the test chooses the path), and do not commit one whose rendering depends on the machine's fonts.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap` (the program a test file runs as), `flutter_application_variant`, `flutter_macos_app`, `flutter_desktop_app_integration_test` and `flutter_desktop_runner`, which the macro composes as `__<name>_bootstrap`, `__<name>_program` and `__<name>_app` (the macro's own targets, which you do not name).

#### Windows integration tests

`flutter_windows_integration_test` runs the same test file on the Windows desktop: the application with the test as its program is built as a Windows bundle in debug mode, launched on the host's own desktop, and its suite driven over its VM service, as `flutter test integration_test/app_test.dart -d windows` does. It is the macOS macro without `bundle_id`.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_windows_integration_test")

flutter_windows_integration_test(
    name = "app_windows_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **Runs on a Windows host** (`target_compatible_with`); a Mac or Linux host skips it. The app is built as for `flutter_windows_app`, whose arguments (`app_name`) the macro passes on, and the runner is `windows/runner/` when the package has one, else the built-in template.
- **The window is real.** The app's window is created on the desktop of the session the test runs in, and the test reads and taps what it draws. Windows that overlap keep drawing, so two tests at once do not hang each other (measured with two windows at one origin), and there is no lock. A session with no visible desktop, such as an SSH logon, still runs the test: the window exists and is not on screen, so a screenshot needs the interactive session.
- **Per-test results, `--test_filter`, tags, `shard_count`, `env`, `data`, goldens and the failures** (a failing case, an app that exits, a suite that registers nothing) are as on macOS; an app that exits says `The Windows app exited with code 3 …`. `bazel run :app_windows_test -- --update-goldens` writes the goldens, the Windows one in `goldens/windows/`.
- **Use a short output base.** Windows limits a path to 260 characters and a Flutter bundle is deep: `bazel --output_base=C:/b test ...`.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap`, `flutter_application_variant`, `flutter_windows_app`, `flutter_desktop_app_integration_test` and `flutter_desktop_runner`, which the macro composes as `__<name>_bootstrap`, `__<name>_program` and `__<name>_app`.

#### Linux integration tests

`flutter_linux_integration_test` runs the same test file on Linux: the application with the test as its program is built as a Linux bundle in debug mode, started on an X server the test starts for itself, and its suite driven over its VM service, as `flutter test integration_test/app_test.dart -d linux` does. It is the Windows macro, passing `flutter_linux_app`'s arguments (`application_id`, `app_name`).

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_linux_integration_test")

flutter_linux_integration_test(
    name = "app_linux_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    application_id = "com.example.app_linux_test",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **Runs on a Linux host** (`target_compatible_with`), x86_64 or arm64; a Mac or Windows host skips it.
- **Nothing of the host's but its C and C++ runtime.** The X server (`Xvfb`), GTK, Mesa's software OpenGL and the fonts come from a pinned runtime: a closure of Debian 13 packages, pinned by path and `sha256` for each architecture and fetched only when a Linux integration test is analysed. The host needs no desktop, no GTK and no X server, and its display, libraries and GTK modules are not used; a test runs the same on a workstation, over SSH and in CI. The host's glibc and libstdc++ must be at least Ubuntu 24.04's (glibc 2.39): the build checks every file of the runtime against that and fails, naming the file, on one that asks for more.
- **Each test has a screen of its own**, so tests run at once without a lock and never draw on your desktop.
- **Per-test results, `--test_filter`, tags, `shard_count`, `env`, `data`, goldens and the failures** are as on macOS; an app that exits says `The Linux app exited with code 3 …`. `bazel run :app_linux_test -- --update-goldens` writes the goldens, the Linux one in `goldens/linux/`.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap`, `flutter_application_variant`, `flutter_linux_app`, `flutter_desktop_app_integration_test` and `flutter_desktop_runner`, whose `linux_runtime` is the runtime (`@flutter_linux_runtime_amd64//:runtime` or `_arm64`, a `flutter_linux_runtime`). `bazel run @rules_flutter//tools/update_linux_runtime -- <snapshot>` re-pins the runtime at a snapshot.debian.org timestamp.

#### Web integration tests

`flutter_web_integration_test` runs the same test file in headless Chrome. `flutter test` refuses web devices (flutter/flutter#66264), and `flutter drive -d chrome` reports only pass or fail; this reports each `testWidgets` as a case, as the other platforms do, with `--test_filter`, tags and `shard_count`.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_web_integration_test")

flutter_web_integration_test(
    name = "app_web_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

It takes the `application` the test runs, as the other platforms' macros do, with `deps` the test imports beyond the application's and `srcs` it imports by relative path; the other `flutter_web_app` arguments (`web_dir`, `base_href`, and the rest) pass through. The test's program is the application with the test as its `main` (`flutter_application_variant`), built as a web app in debug mode whatever `-c` says, served from a directory of its own on the loopback and opened in a headless Chrome.

- **The browser is pinned.** It is Chrome for Testing's headless shell (`@rules_flutter//flutter/integration_test:chrome`), downloaded by version and `sha256` for macOS (arm64, x64), Linux (x64, arm64) and Windows x64, so the page is drawn by the same browser wherever the test runs. Only the host's own is fetched, and only when a web integration test is analysed. A host with no pinned shell skips the test (`@platforms//:incompatible`); it is never run in another browser. `runner` takes a `flutter_chrome_runner` of your own. `bazel run @rules_flutter//tools/update_chrome_for_testing` prints a newer pin.
- **The suite is driven over the browser's DevTools protocol**, which a web bundle has in place of a VM service: the page publishes a hook the host calls, and calls a binding the host added, so there is no port to open and no server of the page's own. The browser's profile is deleted when the test ends, and the browser is killed.
- **A page that is lost fails the target, saying why**: the browser exiting (`Chrome exited with code 139`), the page crashing, or the connection closing; a page that never starts the suite fails at the test's timeout, naming the bootstrap it never reached.
- **On Linux the browser loads the pinned Linux runtime's libraries** (see Linux integration tests), never the host's, and the build checks that it needs none the runtime lacks. It runs without its sandbox, as upstream's headless Chrome does: the sandbox needs unprivileged user namespaces, which Ubuntu denies by default since 23.10, or Chrome's set-user-ID helper installed by root. Windows is not verified yet.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap` (with `src_import = "relative"`: a web compile mounts no file-system root to name the test under), `flutter_application_variant`, `flutter_web_app` or `flutter_web_bundle`, `flutter_web_app_integration_test` and `flutter_chrome_runner`, which the macro composes as `__<name>_bootstrap`, `__<name>_program` and `__<name>_app`.

#### Android integration tests

`flutter_android_integration_test` runs the same test file on an Android emulator the test boots for itself, or on an attached phone: the app is built in debug mode for the device's ABI, installed, started, and its suite driven through the VM service forwarded from the device, as `flutter test integration_test/app_test.dart -d <device>` does.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_android_integration_test")

flutter_android_integration_test(
    name = "app_android_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    application_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

```sh
bazel test :app_android_test        # on an emulator of its own
bazel test :app_android_test \
    --@rules_flutter//flutter/integration_test:android_device=attached \
    --test_env=ANDROID_SERIAL=<serial>  # on your phone
```

- **By default the device is an emulator of the test's own.** The emulator (36.2.12) and the system image it boots (Android 15, API 35, AOSP's Automated Test Device image) are pinned by sha256 and downloaded by Bazel for the host, about 1 GB: macOS on Apple silicon boots the arm64-v8a image, Linux on x86_64 the x86_64 one, and the app is built for it. A build that runs no Android test on the emulator downloads nothing of it. Each test makes a device in its own temporary directory, boots it from a cold start with fresh data and no window (15 to 30 s on an Apple-silicon Mac, depending on its load), runs, and shuts it down however it ends; a test needs nothing attached, booted or installed, and leaves nothing behind. On other hosts (Windows, Intel Macs, Linux on arm64) the test is skipped; run it on an attached device there.
- **The emulator needs the host's hypervisor**: Hypervisor.framework on macOS, KVM on Linux (`/dev/kvm` readable and writable by the user; a cloud VM needs nested virtualisation). Without it the test fails before anything boots, saying so and how to enable it. On Linux the emulator loads the X client libraries it links from the pinned Linux runtime of [Linux integration tests](#linux-integration-tests), not the host's.
- **Tests on emulators run side by side.** Each takes a pair of the ports `adb` knows emulators by (5554 to 5585, passing over those of emulators already running, so 16 at once) under a lock (`/tmp/rules_flutter-locks/android-emulator-<port>.lock`), and Bazel schedules each with three cores, the device's two and one for the emulator. The emulator answers to an `adb` server of the test's own that looks at no USB or network device, so a phone that is attached is never touched. An emulator that a SIGKILL left behind is shut down by the next test that takes its ports. The emulator's output and the device's whole log are kept with the test's outputs (`emulator.log`, `logcat.txt` in `bazel-testlogs/<test>/test.outputs/`).
- **On an attached device** (`--@rules_flutter//flutter/integration_test:android_device=attached`), the test runs on the device `ANDROID_SERIAL` names, else the only one attached; with none, or several and none named, it fails, naming `adb devices` and the variable that picks one. It is a failure, not a skip: a skipped test reads as a pass. Two tests on one device take turns on a lock (`/tmp/rules_flutter-locks/android-<serial>.lock`), which the operating system releases if a test dies. The app is built for arm64-v8a. `ANDROID_SERIAL` given to a test that runs on the emulator fails it, naming the flag.
- **`adb` is the SDK's own**, that of the `@androidsdk` your `MODULE.bazel` already declares for building an APK (downloaded, or found at `ANDROID_HOME`), not one found on `PATH`, and the file the SDK has for the host the test runs on (`adb.exe` on Windows). The `aapt2` that reads the APK's package and launch activity is `@androidsdk`'s too. `runner` takes a runner of your own: `flutter_android_emulator_runner(sdk = ..., emulator = ..., system_image = ...)`, whose `system_image` can be another `flutter_android_system_image` (another API level, say) and whose `cores` and `memory_mb` size the device, or `flutter_android_device_runner(sdk = ...)`.
- **`abi`** (by default the emulator image's, or `arm64-v8a` on an attached device; `x86_64` and `armeabi-v7a` otherwise) is the ABI the app is built for, whatever `--@rules_android//flags:android_platforms` says: it has to be the one the device runs. An emulator runner whose image runs another fails analysis, naming both.
- **`integration_test`'s Android library links into the app**, and its Gradle build asks for `androidx.test:runner`, `androidx.test:rules`, `androidx.test.espresso:espresso-core` and `com.google.guava:guava`. Name a version of each in the `rules_flutter_maven` install of your `MODULE.bazel` (Gradle's `1.2+`, `1.2+` and `3.3+` are ranges; analysis names whatever is missing, and `bazel run @<hub>//android:maven_artifacts` prints the block). Only the tests' apps link it: your own app does not.
- **The app stays installed** on an attached device, as `flutter test` leaves it. `adb uninstall <application_id>` removes it.
- **`env` is refused**: an app started by the device cannot be handed an environment. Pass `defines` to the application instead.
- Results, `--test_filter`, tags, `shard_count`, and the failures (a failing case, an app that exits, a suite that registers nothing) are as on the other platforms.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap`, `flutter_application_variant`, `flutter_android_app`, `flutter_android_app_integration_test`, `flutter_android_emulator_runner`, `flutter_android_system_image` and `flutter_android_device_runner`, which the macro composes as `__<name>_bootstrap`, `__<name>_program`, `__<name>_app` and, when you name no `runner`, `__<name>_emulator` and `__<name>_device`, of which the flag picks one.

#### iOS simulator integration tests

`flutter_ios_simulator_integration_test` runs the same test file on an iOS simulator: the app is built in debug mode for the simulator, and the test makes a simulator of its own, installs and starts the app on it, and drives its suite through the VM service, as `flutter test integration_test/app_test.dart -d <simulator>` does.

```starlark
load("@rules_flutter//flutter:integration_test.bzl", "flutter_ios_simulator_integration_test")

flutter_ios_simulator_integration_test(
    name = "app_ios_test",
    src = "integration_test/app_test.dart",
    application = ":app_flutter",
    bundle_id = "com.example.myapp",
    deps = [
        "@deps//:flutter_test",
        "@deps//:integration_test",
    ],
)
```

- **The simulator is the test's own.** It is created as `rules_flutter-<test>-<pid>` (an iPhone 16 on the newest installed iOS runtime), booted, and shut down and deleted when the test ends, however it ends: a failing test, a crash of the app, a Bazel timeout. It shares nothing with another test or with the simulators you use, so tests need no lock, and `shard_count` shards each get one. `runner` takes a `flutter_ios_simulator_runner(device_type = ..., runtime = ...)` for another device type or runtime (names `xcrun simctl list devicetypes` and `runtimes` list).
- **Needs Xcode and an iOS runtime** (`xcodebuild -downloadPlatform iOS`): a host with none fails the test saying so. It is a failure, not a skip. `DEVELOPER_DIR` reaches the test, so the Xcode you selected for the build is the one `xcrun` uses.
- **The app is built for the arm64 simulator** (`sim_arm64`), in debug mode whatever `-c` says. rules_flutter supports Apple Silicon hosts only: on an Intel Mac the test fails at analysis, saying so.
- **`env` is refused**: an app started by the simulator cannot be handed an environment. Pass `defines` to the application instead.
- Results, `--test_filter`, tags, `shard_count`, and the failures (a failing case, an app that exits, a suite that registers nothing) are as on the other platforms. The test is `macos`-only (`target_compatible_with`), scheduled with two cores (`cpus` of the runner), and runs outside Bazel's sandbox and never remotely.

The macro is Tier 1. Tier 2 is `flutter_integration_bootstrap`, `flutter_application_variant`, `flutter_ios_app`, `flutter_ios_app_integration_test` and `flutter_ios_simulator_runner`, which the macro composes as `__<name>_bootstrap`, `__<name>_program` and `__<name>_app`.

### flutter_android_build

Builds its `targets` for the Android `android_platforms`, as `--@rules_android//flags:android_platforms=<those platforms>` would, whatever flags the command line has. A plain `bazel test //...` then checks an APK for one ABI, or for several, with no `--@rules_android//flags:android_platforms` in the CI job.

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_build")

flutter_android_build(
    name = "my_app_android_fat",
    android_platforms = [
        "@rules_android//:arm64-v8a",
        "@rules_android//:x86_64",
    ],
    tags = ["manual"],
    targets = [":my_app_android"],
)
```

The rule forwards the files of `targets`, so a test names them in `data` and finds the APK in its runfiles. Two builds of one APK share its file name; a test that reads more than one needs each under a name of its own, which `e2e/plugin_example/android_apk.bzl` does with a symlink.

| Attribute | Description |
|---|---|
| `android_platforms` | The platforms to build `targets` for, such as `@rules_android//:armeabi-v7a`, `@rules_android//:arm64-v8a` and `@rules_android//:x86_64`. Your `MODULE.bazel` needs a `bazel_dep` on `rules_android` to name them in a BUILD file. Required. |
| `targets` | The targets to build, such as a `flutter_android_app`. Required. |

### flutter_android_release

Signs an App Bundle and the APK of the same release build with your upload key when you `bazel run` it. See [Release: App Bundle and signing](#release-app-bundle-and-signing).

```starlark
load("@rules_flutter//flutter:android.bzl", "flutter_android_release")

flutter_android_release(
    name = "app_release",
    app_bundle = ":app_bundle",
)
```

| Attribute | Description |
|---|---|
| `app_bundle` | An `android_application`: `flutter_android_app`'s `app_bundle`, or your own built from the composable rules with `bundle_config_file = "@rules_flutter//flutter:android_bundle_config.pb.json"`. Built in release mode for `android_platforms`. Required. |
| `android_platforms` | The ABIs of the release build. Defaults to `@rules_android//:armeabi-v7a`, `@rules_android//:arm64-v8a` and `@rules_android//:x86_64`. |
| `key_properties` | Where `key.properties` is, relative to the target's package in the source tree. A path, not a label, so the file never enters the build. Defaults to `android/key.properties`. |

Commands, after `--`:

| Command | Flags |
|---|---|
| `sign` (the default) | `--key-properties=<path>`, `--output-dir=<dir>` |
| `create-key` | `--key-properties=<path>`, `--dname=<X.500 name>` (default `CN=Upload Key`) |

Relative paths in flags are relative to the directory you ran `bazel run` from. The Java runtime (`--java_runtime_version`) must be a full JDK, such as `remotejdk_25`, since signing uses its `jarsigner` and `keytool`.

### flutter_profile_build

Builds its `targets` in profile mode, as `-c opt --@rules_flutter//flutter:profile` would, whatever flags the command line has. A plain `bazel test //...` then checks a profile build, with no `--config=profile` in the CI job.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_profile_build")

flutter_profile_build(
    name = "my_app_profile",
    tags = ["manual"],
    targets = [":my_app"],
)

dart_test(
    name = "profile_bundle_test",
    data = [":my_app_profile"],
    main = "test/profile_bundle_test.dart",
)
```

The rule forwards the files of `targets`, so a test names them in `data` and finds them in its runfiles. `tags = ["manual"]` keeps `bazel build //...` from building the profile app on every run; the test that depends on it builds it. Profile mode needs the profile engine and `gen_snapshot` of the target platform, which are downloaded the first time, and the AOT snapshot cannot be built for another desktop OS, so put `target_compatible_with` on the target and its test as you would on the app. There is no profile mode for the iOS simulator.

| Attribute | Description |
|---|---|
| `targets` | The targets to build in profile mode, such as a `flutter_macos_app`. Required. |

### flutter_plugin

Declares a Flutter plugin written in your workspace: its Dart code plus per-platform native implementations. Plugins from pub do not need this; the hub declares them.

Each platform the plugin registers on is a `flutter_plugin_platform`, as each entry of `flutter: plugin: platforms:` is in a pubspec, holding that platform's registration and its native library:

```starlark
flutter_plugin_platform(
    name = "ios",
    platform = "ios",
    plugin_class = "AudioSessionPlugin",
    lib = ":audio_session_apple",
)

flutter_plugin_platform(
    name = "web",
    platform = "web",
    plugin_class = "AudioSessionWeb",
    file_name = "audio_session_web.dart",
)

flutter_plugin(
    name = "audio_session",
    srcs = glob(["lib/**/*.dart"]),
    platforms = [
        ":ios",
        ":web",
    ],
)
```

| Attribute of `flutter_plugin_platform` | Description |
|---|---|
| `platform` | `android`, `ios`, `linux`, `macos`, `web` or `windows`. Required. |
| `plugin_class` | `pluginClass`: the class registered with the platform's plugin registry. On web, the Dart class whose `registerWith(Registrar)` the web registrant calls. |
| `dart_plugin_class` | `dartPluginClass`: the Dart class whose `registerWith()` runs before `main()`. |
| `dart_file_name` | `dartFileName`: the library under `lib/` that declares `dart_plugin_class`. Defaults to `<package>.dart`. Not on web. |
| `file_name` | `fileName`: the library under `lib/` that declares a web `plugin_class`. Defaults to `<package>.dart`. Web only. |
| `ffi_plugin` | `ffiPlugin`: the platform's native code is a library Dart opens through `dart:ffi`. |
| `default_package` | `default_package`: the package that implements a federated plugin on this platform. |
| `package` | `package`: the Java package of an Android `plugin_class`. Android only, and required with a `plugin_class`. |
| `lib` | The platform's native library: a `flutter_apple_plugin_library` on iOS and macOS, a `flutter_linux_plugin_library` or `flutter_windows_plugin_library` on the desktops. Only a build for `platform` analyses it. Not on Android or web. |

A platform has a `plugin_class`, a `dart_plugin_class`, `ffi_plugin` or a `default_package`, as flutter_tools requires.

| Attribute of `flutter_plugin` | Description |
|---|---|
| `srcs` | Dart sources. |
| `deps` | `dart_library` or `flutter_library` targets. |
| `platforms` | A `flutter_plugin_platform` for each platform the plugin registers on. |
| `exports` | The plugin's Android library, in a `select()` on `@platforms//os:android`. Android apps that depend on the plugin link it. It is here rather than on the `android` platform because rules_android's dexing reaches a library through `exports` and no other attribute. |
| `native_deps` | Shared libraries bundled for `dart:ffi`. |
| `data_assets` | `flutter_data_asset` targets, bundled at `flutter_assets/packages/<package>/<name>`. |
| `assets`, `resources` | Asset and resource files. An asset is keyed as on `flutter_library`. |
| `shaders`, `shader_includes` | The package's fragment shaders and what they `#include`, as on `flutter_library`. |
| `fonts` | The package's font families, as on `flutter_library`. |
| `package` | The package's `dart_package_metadata`, as on `flutter_library`. It states the package's name, language version and version, its `hook/link.dart` (see [Link hooks](#link-hooks)) and its `NOTICES` or `LICENSE` file, as `flutter build` reads it from the package root: programs that depend on the package list that file in their `NOTICES`. |

A plugin's native code is its own target. Swift goes in a `flutter_apple_plugin_library`, the `lib` of the `ios` or `macos` platform; one with `platform = "darwin"` compiles for whichever of the two the build is for, so a plugin whose sources are shared (`sharedDarwinSource`) names the one library as the `lib` of both. Kotlin or Java goes in a `flutter_android_plugin_library`, passed as `exports` in a `select()` on `@platforms//os:android` (an empty list otherwise). Every Android app that depends on the plugin then links it, as it links a pub plugin's library: `flutter_android_app` packages it, registers its plugin class and merges its `manifest` (receivers, services, permissions) into the app's. It gets a generated `BuildConfig` in its `java_package`, with `DEBUG` and `BUILD_TYPE` as Gradle's would be in the build's mode. Its `flutter_engine` is a `flutter_android_engine(neverlink = True)`: the plugin compiles against the engine and the app ships its own, of the app's ABI. `e2e/plugin_example/glass_plugin` shows both, with shaders.

`e2e/ffi_example` shows a plugin built on Native Assets, `e2e/ffi_plugin_example` one with a Dart plugin class and `native_deps`, and `e2e/plugin_example` one with a Dart plugin class only.

### Link hooks

A package can decide what it ships from how the app uses it. Mark a `final class` with `@RecordUse()` from `package:meta` (1.19 or later), and write a `hook/link.dart` that reads the recorded uses with `package:record_use` and emits data assets with `package:data_assets`. The hook may import pure Dart from its own package's `lib/`, not Flutter.

```starlark
# symbols/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "symbols",
    link_hook = "hook/link.dart",
)

flutter_plugin(
    name = "symbols",
    srcs = glob(["lib/**/*.dart"]),
    package = ":pubspec-metadata",
    platforms = [],
    deps = ["@deps//:data_assets", "@deps//:hooks", "@deps//:meta", "@deps//:record_use"],
)

# app/BUILD.bazel
dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "app",
)

flutter_application(
    name = "app",
    package = ":pubspec-metadata",
    link_hook_assets = ["package:symbols/index.json"],
    deps = ["//symbols", "@deps//:flutter"],
    # ...
)
```

Keep the hook file out of `srcs`. Bazel names every output before anything runs, so the application lists each asset its packages' hooks emit. A hook that emits an asset not listed, skips one that is, or reports an error fails the build with its own message. An application that sets `link_hook_assets` runs the hook of every package in its `deps` that has one.

In a release or profile build the kernel compile records the uses (`--recorded-uses`), each hook runs over them, and the assets are bundled at `flutter_assets/packages/<package>/<name>`, listed in `AssetManifest`, and loaded with `rootBundle.load('packages/<package>/<name>')`. Debug builds are JIT compiles, which record nothing: no hook runs and no asset is bundled, so load what the hook would have indexed on demand there. `e2e/_overlay_tests/link_hooks` is a working example, including the failing case.

### Lower-level rules

These are what `flutter_application` is made of. Most apps never need them.

| Rule | What it does |
|---|---|
| `flutter_kernel` | Compiles Dart to a kernel `.dill` with Flutter's patched platform kernel. |
| `flutter_aot_snapshot` | Compiles Dart to an AOT shared library (`.so` on Linux and Android, `.dylib` on macOS) with `gen_snapshot`. |
| `flutter_asset_bundle` | Builds the `flutter_assets/` tree: `AssetManifest.bin`, `FontManifest.json`, `NOTICES.Z`, and the asset files. |
| `flutter_native_library` | Pairs a native library with its binding contract. See [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). |
| `flutter_data_asset` | Declares a Dart data asset, from `@rules_flutter//flutter:native_assets.bzl`. It is bundled at `flutter_assets/packages/<package>/<name>`. A code asset is rules_dart's `dart_code_asset`. |

### Code generation

rules_dart provides `dart_codegen` and `dart_aggregate_codegen`, which replace `build_runner` with ordinary Bazel actions. They load from `@rules_dart//dart:defs.bzl`. A generated file goes into the consuming target's `srcs`, and the rules place it next to its hand-written sibling so a `part` directive resolves:

```starlark
load("@rules_dart//dart:defs.bzl", "dart_aggregate_codegen", "dart_codegen")
load("@rules_flutter//flutter:defs.bzl", "dart_package_metadata")

dart_package_metadata(
    name = "pubspec-metadata",
    package_name = "my_app",
)

# One output per input file, for example a json_serializable part.
dart_codegen(
    name = "user_json",
    package = ":pubspec-metadata",
    src = "lib/user.dart",
    generator = "tools/json_generator.dart",
    output_suffixes = [".g.dart"],
)

# One output from all the inputs, for example a route registry.
dart_aggregate_codegen(
    name = "registry",
    package = ":pubspec-metadata",
    srcs = ["lib/model.dart", "lib/order.dart"],
    generator_script = "tools/aggregate_generator.dart",
    outputs = ["lib/registry.g.dart"],
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = ["lib/user.dart", ":user_json", ":registry"],
    deps = ["@deps//:flutter"],
)
```

`e2e/codegen` is the worked example, including generated code in dependency packages and hot reload over regenerated sources.

#### go_router_builder

rules_dart ships macros for pure-Dart builders such as json_serializable and freezed, written on its builder API (`@rules_dart//dart/ext:defs.bzl`). go_router_builder states a Flutter constraint, so rules_flutter ships it: `go_router_codegen` writes the `<src>.g.dart` part of each source that declares `@TypedGoRoute` routes, as `dart run build_runner build` would. The builder comes from rules_flutter's own lock; your lock needs `go_router`, which the generated code and your sources import.

```starlark
load("@rules_flutter//ext/go_router:defs.bzl", "go_router_codegen")

# lib/routes.dart declares `part 'routes.g.dart';`.
go_router_codegen(
    name = "routes",
    srcs = ["lib/routes.dart"],
    annotation_dep = "@deps//:go_router",
    package = ":pubspec-metadata",
    deps = ["@deps//:flutter"],
)

flutter_application(
    name = "my_app",
    package = ":pubspec-metadata",
    main = "lib/main.dart",
    srcs = ["lib/routes.dart", ":routes"],
    deps = ["@deps//:flutter", "@deps//:go_router"],
)
```

`annotation_dep` names your `go_router` library; it is `@pub_deps//:go_router` unless you set it, so a hub named `pub_deps` can leave it out. `config` takes the builder's options as JSON, as `build.yaml` states them. For Gazelle to write these targets, register the builder in the BUILD file at your repository's root:

```starlark
# gazelle:dart_builder TypedGoRoute macro=@rules_flutter//ext/go_router:defs.bzl%go_router_codegen shim=@rules_flutter//ext/go_router:shim produces=.go_router.g.part runtime_dep=@pub_deps//:go_router key=go_router_builder:go_router_builder
```

`runtime_dep` names the same library as `annotation_dep`: with the hub `deps`, `runtime_dep=@deps//:go_router`.

#### flutter_gen_l10n

Generates `AppLocalizations` from `.arb` files, the equivalent of `flutter gen-l10n`.

```starlark
load("@rules_flutter//flutter:defs.bzl", "flutter_gen_l10n")

flutter_gen_l10n(
    name = "app_l10n",
    arbs = [
        "lib/l10n/app_en.arb",
        "lib/l10n/app_es.arb",
        "lib/l10n/app_es_419.arb",
    ],
)

flutter_test(
    name = "l10n_test",
    package = ":pubspec-metadata",
    srcs = [":app_l10n"],
    main = "test/l10n_test.dart",
    deps = [
        "@deps//:flutter",
        "@deps//:flutter_localizations",
        "@deps//:flutter_test",
        "@deps//:intl",
    ],
)
```

The generated files land beside the `.arb` files, and a consumer collects them by listing the target in `srcs`. The attributes mirror the flags of `flutter gen-l10n` with the same defaults: `template_arb_file`, `output_class`, `use_deferred_loading`, and so on. `l10n.yaml` is not read, because Bazel has to know the output file names during analysis and a config file read while the action runs cannot tell it.

A few things to know:

- **Keep `@@locale` consistent with the filename.** The rule derives output names from the arb filenames, while the generator decides what to write from each file's `@@locale`. If `app_english.arb` declares `"@@locale": "en"`, Bazel expects `app_localizations_english.dart` and the generator writes `app_localizations_en.dart`, which surfaces as "output was not created". Bazel cannot read file contents during analysis, so the rule cannot check this for you.
- **Outputs are grouped by primary language.** `app_es.arb` and `app_es_419.arb` produce one `app_localizations_es.dart` holding both classes, matching upstream.
- **Generated files always use LF line endings.** Upstream copies the line endings of `pubspec.yaml`, which would make the output depend on a file the action does not declare.
- **There is no `format` attribute.** Formatting shells out to the `dart` binary, which the action does not have. Setting it is an error rather than a silent no-op. rules_dart's format check covers hand-written files only, so the generated sources are not checked.
- **Two copies of `intl` are in play.** The generator has its own. An app using the generated code needs `intl` in its own lock. Upstream has the same split.

The generator is carved out of `flutter_tools` at fetch time with a set of patches, so a Flutter version bump re-validates it. A release that moves the patch context fails the patch, and a new release also needs a `source_sha256` in `flutter/private/versions.bzl`. Two things those checks cannot catch: a newly added read of an undeclared file at run time, which shows up as a `PathNotFoundException`, and a newly adopted `dart:io` API newer than the Dart that rules_dart provides, which shows up as a compile error naming a missing type. The fix for the second is to cut the dead code that uses it, as the existing patches do for an unused `NetworkInterface` wrapper. See `flutter/private/flutter_gen_l10n_repo.bzl`.

On Windows, the repository rule extracts all of `packages/flutter_tools` (about 19 MB) and uses twenty of its files. The deepest path is around 130 characters from the repository root, which fits within `MAX_PATH` given a short `output_user_root`.

### Providers

**`FlutterSdkInfo`** comes from the toolchain and carries the engine binaries and SDK files a custom rule needs:

```starlark
sdk = ctx.toolchains["@rules_flutter//flutter:toolchain_type"].flutter_sdk_info
```

| Field | Type | Description |
|---|---|---|
| `version` | `str` | The Flutter SDK version, for example `"3.47.9"`. |
| `engine_revision` | `str` | The engine commit hash. |
| `dart` | `File` | The `dart` executable from the bundled Dart SDK. |
| `dartaotruntime` | `File` | The runtime for AOT snapshots. |
| `gen_snapshot` | `File` | The AOT compiler. |
| `frontend_server` | `File` | `frontend_server_aot.dart.snapshot`, for kernel compilation. |
| `platform_kernel_dill` | `File` | `platform_strong.dill`, the debug platform kernel. |
| `platform_kernel_dill_product` | `File` | `platform_strong_product.dill`, the release platform kernel. |
| `patched_sdk` | `Target` | The Flutter-patched Dart SDK root. |
| `icu_data` | `File` | `icudtl.dat`. |
| `sdk_files` | `DartSdkFilesInfo` | The bundled Dart SDK's files by the use that reads them (`run`, `aot_run`, `kernel`, `dart2js`, `dart2wasm`, ...), as rules_dart declares them. An action takes the set of the one tool it runs. |
| `tool_files` | `depset[File]` | Every file of the bundled Dart SDK and the patched SDK (~1,050 files, 650 MB), for running any SDK command such as `dart pub`. An action that runs one tool takes that tool's set from `sdk_files` instead. |
| `engine_library` | `Target` or `None` | The platform engine runtime library of the build mode (debug under `-c dbg`, profile under `--@rules_flutter//flutter:profile` where the toolchain has one, release otherwise). `None` for mobile and web. |
| `const_finder` | `File` or `None` | `const_finder.dart.snapshot`, for icon tree shaking. |
| `font_subset` | `File` or `None` | The `font-subset` binary. |
| `impellerc` | `File` or `None` | The shader compiler. |
| `shader_lib` | `list[File]` | Shader include files for impellerc. |
| `target_os`, `target_arch` | `str` | The cross-compilation target, or empty for a native build. |

**`FlutterInfo`** is carried by `flutter_library` and `flutter_plugin`:

| Field | Type | Description |
|---|---|---|
| `pub_assets` | `depset[struct]` | The asset files of each package, each with its `package_name`, its `package_root`, its path from that root and the file. A program bundles them as `packages/<package_name>/<path>`, or as `<path>` when the package is the program's own. |
| `plugins` | `list[struct]` | Plugin metadata, each with `name` and `platforms`, a dict of platform to the `FlutterPluginPlatformInfo` of its `flutter_plugin_platform`. |
| `transitive_native_libs` | `depset[File]` | Shared libraries from plugins' `native_deps`. |

**`FlutterFontFamilyInfo`** is carried by `flutter_font_family`: its `family`, and its `fonts`, a `FlutterFontInfo` each (`file`, `weight`, `style` and `asset`, as on `flutter_font`). **`FlutterPluginPlatformInfo`** is carried by `flutter_plugin_platform`: its attributes, with `lib` the native library of a build for its platform, or `None`.

**`FlutterApplicationInfo`** is carried by `flutter_application` and consumed by the platform rules:

| Field | Type | Description |
|---|---|---|
| `aot_output` | `File` or `None` | AOT native code. `None` in debug mode. |
| `kernel_dill` | `File` or `None` | The kernel `.dill`. `None` in release mode. |
| `flutter_assets` | `File` | The `flutter_assets/` tree. |
| `icu_data` | `File` | `icudtl.dat`. |
| `native_libs` | `list[File]` | Shared libraries from `native_deps`. |
| `is_debug` | `bool` | `True` for a debug build. |
| `native_plugin_registrant` | `File` or `None` | The generated plugin registrant source for desktop platforms. |

**`FlutterApplicationInputsInfo`** is carried by `flutter_application` and `flutter_application_variant`. Its one field, `inputs`, is the program the application was built from, which `flutter_application_variant` changes and builds again.

**`FlutterTestProgramInfo`** is returned by `flutter_suite_program` and read by `flutter_program_test`: a compiled Flutter test and what the runner needs beside it.

| Field | Type | Description |
|---|---|---|
| `kernel` | `File` | The kernel `flutter_tester` is started with: a `.dill`, or, with `kernel_list`, a list of the kernels in `kernels`, which the runner joins into one when it starts `flutter_tester`. |
| `kernel_list` | `bool` | Whether `kernel` is a list of kernels. |
| `kernels` | `depset[File]` | The kernels `kernel` names; empty for a joined kernel. |
| `assets` | `File` | The `flutter_assets` directory the test runs with. |
| `tester`, `icu_data` | `File` | `flutter_tester` and its ICU data, for the platform the program is built for. |
| `display_path` | `str` | The suite's path in the runner's reports. |
| `source` | `File` | The test library's source, read for its `@Tags`. |
| `packages` | `list[DartPackageInfo]` | Every package the program runs, its own included, by which `bazel coverage` finds the file of each library it reports. |
| `native_assets_manifest` | `File` | The Native Assets manifest the kernel was compiled with. |
| `native_files` | `list[str]` | Runfiles paths of native-asset libraries the runner puts on the loader's search path (Windows); empty elsewhere. |
| `enable_impeller` | `bool` | Whether the test renders with Impeller. |
| `target_os` | `str` | The OS the program is built for. |
| `runfiles` | `runfiles` | Everything the program needs when it runs, less the runner: every File above, native-asset libraries and `data`, goldens included. |

**`FlutterIntegrationRunnerInfo`** is returned by the runner rules (`flutter_desktop_runner`) and read by the test rule of the same family: the `family` of device (`"web"`, `"desktop"`, `"ios_simulator"` or `"android"`), the runner's own `launcher_config`, the `runfiles` it needs, the test's `execution_requirements` and `target_compatible_with`. A test rule takes only a runner of its own family.

## The dev tool

`flutter_bazel`, in `tools/dev_tool/`, is the development loop: it builds a target, installs and launches it on a device, and gives you hot reload and hot restart. It speaks the same `--machine` JSON-RPC protocol as `flutter run`, so the existing IDE plugins for VS Code and IntelliJ work with it. It also opens an HTTP channel that scripts and coding agents can use to drive the running app.

### Running an app

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- run -t //:my_app_macos -d macos
```

`run` builds the target, launches it, and then watches the filesystem. Saving a Dart file triggers a hot reload. The flags most people use:

| Flag | What it does |
|---|---|
| `-t`, `--target` | The Bazel target to build and run. Required. |
| `-d`, `--device` | Where to run it. Repeat for several devices at once. See below. |
| `-c`, `--compilation_mode` | Bazel's compilation mode: `dbg`, `opt` or `fastbuild`. A hot reload run builds `dbg` and a profile run `opt`; naming another with those is refused. |
| `--config` | A config from your workspace's `.bazelrc`, passed to Bazel as `--config=<name>` on every Bazel command of the run, reloads included. Repeatable. |
| `--build-arg` | An extra argument for `bazel build`. Repeatable. |
| `--dart-define KEY=VALUE` | A Dart define, forwarded to the build and replayed on reload and restart. Repeatable. |
| `--no-hot` | Run without hot reload. |
| `--profile` | Profile mode: AOT with the Dart VM service, for DevTools. Builds `-c opt --@rules_flutter//flutter:profile`. Not on the iOS simulator. |
| `--start-paused` | Hold the app at the start of `main()` until a debugger resumes it. |
| `--route` | The initial route. |
| `--no-watch` | Do not reload on save. Watching is on in terminal mode and off in `--machine` mode. |
| `--no-devtools` | Do not launch DevTools. |
| `--machine` | Speak the JSON-RPC protocol on stdout. |
| `--no-http-control-channel` | Do not open the HTTP channel. |
| `--wasm`, `--no-wasm` | On the web, run the dart2wasm build (`--wasm`) or the DDC dev loop (`--no-wasm`). With neither, the target decides: a `flutter_web_app` or `flutter_web_bundle` with `js_fallback = False` ships WebAssembly only, so it runs under dart2wasm, and the startup output says so; any other runs the DDC dev loop. The `app.*` agent commands work under dart2wasm. There is no hot reload: dart2wasm has no incremental compiler and cannot swap code into a running module, so a restart rebuilds and reloads the page, and a typed `--hot` is refused. `--no-wasm` on a WebAssembly-only app runs it under DDC anyway, with a warning: code that only works under WebAssembly (an `Int64List`) fails there. |
| `--web-port`, `--web-hostname`, `--web-launch-url`, `--web-viewport`, `--web-run-headless`, `--web-header`, `--web-browser-flag` | Web dev server and browser settings. `--web-viewport 393x660@3` lays the app out at a phone-sized viewport regardless of the window. |

`flutter_bazel build` builds without running, and `flutter_bazel attach --debug-url <uri>` attaches to an app that is already running. `--help` on each command lists everything.

### Shorter commands with bazel_env

[bazel_env.bzl](https://github.com/buildbuddy-io/bazel_env.bzl) puts Bazel-built tools on your `PATH` under names you choose, so the dev tool becomes a two-letter command. Add it to `MODULE.bazel` and declare the tool:

```starlark
# MODULE.bazel
bazel_dep(name = "bazel_env.bzl", version = "0.9.0", dev_dependency = True)
```

```starlark
# BUILD.bazel
load("@bazel_env.bzl", "bazel_env")

bazel_env(
    name = "bazel_env",
    tools = {
        "fl": "@rules_flutter//tools/dev_tool:flutter_bazel",
    },
)
```

Then run `bazel run //:bazel_env` once. It builds the tool, writes a shim to `.bazel_env/bin/fl`, and prints setup instructions for [direnv](https://direnv.net), which amount to this `.envrc` next to `MODULE.bazel`:

```sh
watch_file .bazel_env/bin
PATH_add .bazel_env/bin
if [[ ! -d .bazel_env/bin ]]; then
  log_error "ERROR[bazel_env.bzl]: Run 'bazel run //:bazel_env' to regenerate .bazel_env/bin"
fi
```

After `direnv allow`, the command is `fl run -t //:my_app_macos -d macos`, from any directory in the workspace. The shim finds the workspace root with `bazel info workspace`, so it does not depend on being launched by `bazel run`. Add `.bazel_env` to `.gitignore`. Without direnv, `bazel run //:bazel_env print-path` prints the directory to add to `PATH` yourself.

The rest of this section spells the command out in full so it works before you set this up.

### Choosing a device

`-d` takes:

| Id | Reaches |
|---|---|
| `macos`, `linux`, `windows` | The host desktop. |
| `chrome` | A browser, through the dev module server. |
| `ios-simulator`, `ios-simulator:<udid>` | The booted simulator, or the one named. |
| `ios`, `ios:<udid>` | The attached iPhone, or the one named. |
| `android`, `android:<serial>` | Whichever device `adb` picks, or the one named. |

An id has to say what kind of device it names, so a bare UDID or serial is refused: an emulator is `-d android:emulator-5554`, not `-d emulator-5554`. Guessing the kind would mean asking `simctl`, `devicectl` and `adb` on every launch. When an id is refused, the tool asks them then, and names the form to pass, for example `pass -d ios-simulator:<udid>`.

For `-d ios`, the tool lists attached devices with `devicectl` and ignores devices that were paired once but are not attached now. With two attached, it asks for `-d ios:<udid>` rather than guessing. A device has two identifiers, the hardware UDID Xcode shows and the CoreDevice UUID that `devicectl` prints, and either works there.

### Hot reload and hot restart

In terminal mode, press `r` to reload and `R` to restart, or just save a file. A reload compiles only the changed libraries and injects them into the running isolate, keeping app state. A restart re-runs `main()`, so it also reflects changes to code that runs only at startup.

An edited shader reloads too, including one from a package in your workspace and one whose `#include` you changed: the reload recompiles it and has the engine reinitialize the program, as `flutter run` does. A web page cannot reinitialize a shader, so there the reload says so and a restart picks it up.

An app whose `main` sits outside its package's `lib/` reloads and restarts the same way, like `flutter run -t test_driver/app.dart`. Such a file has no `package:` URI, so the build and the dev loop both compile it as `org-dartlang-app:///<its workspace path>`. Edits to it, and to the files it imports by relative path, are picked up because the build lists them: its compile can read only the `main` and the `srcs` you declare, so declare the siblings in `srcs`. As in any Dart program, reach code under `lib/` through `package:` imports, not `../lib/...`. A relative import there loads a second copy of that library, and its types stop matching the originals.

A restart can go one step further. Dart code can be swapped into a running process, but a native library the process has already loaded cannot. So when a rebuild changes one of the app's native libraries (`native_deps` or Native Assets, including the `.framework` each becomes on iOS), `app.restart` with `fullRestart: true` relaunches the process instead of restarting the isolate, and says so in its response. If the replacement cannot launch, for example because the device has no room for the new install, the restart fails with the reason and the run ends, since the old process is already gone. The HTTP channel, its token, and the `appId` stay the same across a relaunch. Only the log buffer starts over.

A hot reload cannot relaunch anything, because replacing the process is exactly the state loss a reload exists to avoid. When a reload rebuilds a native library, what happens depends on whether the bindings changed with it, which is what `flutter_native_library`'s `binding_contract` tells the tool. See [Hot reload across a native rebuild](#hot-reload-across-a-native-rebuild). Without that declaration, the reload is withheld and a restart picks up the library. A plain Dart edit takes the fast path: the check costs a `stat` per declared file and reaches Bazel only when one of them moved.

### App output

A running app's console output (`print`, `debugPrint`, `NSLog`, Java stack traces, uncaught errors) is forwarded for the whole run, starting before the VM service is up so that startup failures are visible.

In terminal mode the app's stdout goes to the tool's stdout and its stderr to the tool's stderr, matching `flutter run`. With more than one `-d`, lines are prefixed with `[<device>] `. In `--machine` mode the output arrives as `app.log` events, and nothing else is written to raw stdout, which belongs to the protocol stream.

Each platform has exactly one log source, because a Dart `print()` reaches both the process's stdout and the VM service's `Stdout` stream, and reading both would duplicate every line:

| Platform | Source |
|---|---|
| macOS, Linux, Windows | The process's stdout and stderr. |
| Android | `adb logcat`, filtered to `flutter*`, `DartVM`, `AndroidRuntime`, `System.err`, and fatal records. |
| iOS simulator | A `simctl spawn log stream` scoped to the app process. |
| iOS device | `devicectl --console` plus lldb's output. lldb stays attached for the whole run. |
| Chrome, dev loop | The DWDS VM service's `Stdout` and `Stderr` streams. |
| Chrome, WASM or production JS | Chrome DevTools Protocol console events. |
| `attach` | The VM service's `Stdout` and `Stderr` streams, since there is no process to read. |

### Assets and fonts

An edit to a bundled asset goes live on hot reload or on save, the same as a Dart edit. The tool knows which workspace directories feed the `flutter_assets` tree, so it can tell whether an asset changed from a few directory listings. A run whose assets are untouched never pays for a `bazel build` on a Dart edit.

When an asset has changed, the bundle is rebuilt and only the differing entries are uploaded into the app's devFS. That is what makes it work on a phone, inside an APK, and inside a sandboxed macOS app, none of which can read `bazel-out`. Everything else still resolves to what shipped, because the engine keeps the original bundle behind the devFS directory. A changed font also re-registers the engine's font collection, so re-exporting a `.ttf` takes effect where upstream waits for a restart.

On the web the dev server serves `assets/` from the build tree on every request, so only the page's caches are dropped. Fonts are the exception: the web engine registers them once at startup with no reload hook, and the reload says so rather than reporting success.

### Debugging from the first line

`flutter_bazel run --start-paused` holds the app at the beginning of `main()` so a debugger can attach before any app code runs. Each platform gets the switch the way it accepts one: an engine switch on desktop, an intent extra on Android, argv on iOS. On the web there is no switch; DWDS holds `main()` until a client resumes it, so the tool withholds the run request.

The pause is reported only once the tool has observed it from the main isolate's own pause event, so a target that ignored the switch is called out rather than leaving you waiting at a debugger for an app that already ran. While paused, `app.*` commands answer with the reason instead of blocking, and `--route` and `--trace-startup` are skipped with a warning, because both need a framework that has not started.

### Physical iOS devices

On every platform except iOS hardware, the VM service URI arrives in the app's log: the engine prints it, and the tool reads it off the same stream that carries app output.

An iPhone is different. A wirelessly attached device has no console channel at all, and a wired device's console belongs to the `devicectl` call that launched the app. So the tool finds the URI through the app's mDNS advertisement instead. Every Flutter app built in debug or profile mode advertises `_dartVmService._tcp` with its port and auth code, and the generated debug and profile `Info.plist` declares the matching `NSBonjourServices` entry, so this works for any app built with these rules and no configuration.

| Connection | VM service host | Port |
|---|---|---|
| Wired | `127.0.0.1` through an `iproxy` forward, because the service binds to the device's loopback. | The advertised port, forwarded. |
| Wireless | The device's own address, from the advertisement. | The advertised port, dialed directly. |

The tool picks the pair from what `devicectl list devices` reports. A wireless launch also passes `--vm-service-host=0.0.0.0` so the service is reachable off-device, and a wired launch does not.

When discovery fails, three things are worth checking:

- **Local Network permission.** On macOS the mDNS socket needs it. If it is denied, the error names System Settings > Privacy & Security > Local Network. The device also prompts once, the first time an app advertises.
- **Lost queries.** mDNS is UDP and the spec requires retransmission. Against a USB-attached iPhone a single query succeeded about two times in five, so the tool retransmits with the specified backoff. In practice it resolves in around 200 ms, with 3.3 s the worst observed.
- **`dns-sd` does not show what this tool sees**, in either direction. It answers from mDNSResponder's table, which includes records a raw multicast socket cannot reach: over USB, CoreDevice proxies the device's Bonjour records in as local-only registrations. So `dns-sd` listing the phone while the tool sees nothing over USB is correct on both sides. The table also keeps stale `_dartVmService` records on `lo0` from booted simulators with no app running. Unplugged, the phone multicasts for real on `en0` or `en1` and the raw socket sees it. If you do use `dns-sd`, read the interface index on each `Add` line; interface 1 is `lo0` and proves nothing about the device.

**Launch times.** Expect the first log line to take longer than on a host. A debug build runs under the JIT breakpoint, and the engine traps to the debugger for every executable page it allocates, with each trap writing to device memory over the debugserver link. On a recent iPhone with a healthy Xcode install, the time from resume to the engine's first log line measured about 8 seconds over a cable and about 40 seconds over Wi-Fi. A cable is several times faster, but Wi-Fi works.

A launch that takes minutes means something is wrong on the host, not the phone. The usual cause is an unfinished Xcode symbol copy, which leaves lldb without the shared cache. Check that Xcode has finished copying symbols for the device before looking anywhere else. The tool prints a "still waiting" note at 45 seconds so a slow launch stays distinguishable from a hang.

Hot reload and restart get the same allowance. A reload is quick, since only the changed library is compiled. A restart re-runs `main()` and pays the breakpoint cost again, so it takes about as long as the launch. The per-call budget is five minutes wired and fifteen wireless, against thirty seconds on a host. Those are backstops for a run that will never succeed, sized for the slowest host state seen rather than the seconds a healthy one takes, because a budget that is too short does worse than wait less: it abandons the RPC and force-closes the VM service connection, reporting a timeout for a restart that was about to succeed.

**Debugger stops.** On iOS 26 and later the engine announces each new page of JIT code at a breakpoint, and the debugger has to write the page before the app may run it. The tool resumes every one of those stops itself rather than letting lldb continue on its own: lldb loses some of them when two threads allocate code at once ([llvm/llvm-project#190956](https://github.com/llvm/llvm-project/issues/190956)), and the app then stops on `EXC_BAD_ACCESS (code=50)` with its VM service silent. `flutter_tools` handles it the same way. Any other stop, such as a native crash, is written to the app's output with a backtrace, and the debugger detaches and the run ends, as it does when an app exits on any other platform. Stopping a run, or a launch that fails part way, terminates the app on the device and every helper process it started.

For log output, `devicectl --console` also carries devicectl's own progress banners, and lldb's output is included because lldb holds the debugserver the JIT depends on. Upstream does the same: with Xcode 26 and later, `flutter_tools` reads both, noting that `idevicesyslog` stopped working.

### Driving the app from a script

`flutter_bazel run` opens an HTTP control channel by default. IDE integrations, coding agents, and end-to-end test harnesses can drive the running app through it without a terminal: tap widgets, enter text, read text back, take screenshots, reload, restart, and shut down.

```sh
bazel run @rules_flutter//tools/dev_tool:flutter_bazel -- \
  run -t //:my_app_macos -d macos --machine
```

On stderr, the tool prints the channel's record. Under `LOG_FORMAT=json` it is one JSON line that carries every endpoint with a ready-made URL, token included. The token is a query parameter, not an `Authorization` header:

```json
{"message":"http_control_channel","uri":"http://localhost:PORT",
 "token":"...","tokenParam":"token","endpoints":[
   {"method":"POST","path":"/command",
    "url":"http://localhost:PORT/command?token=...", ...}, ...]}
```

The channel's record lists the per-app endpoints as templates, with `{appId}` in the path. Once an app is up, a `session_ready` record names it and carries those endpoints again with the id filled in, next to `uri` and `token`, so a client reading stderr has everything in one line:

```json
{"message":"session_ready","appId":"___my_app_macos_macOS","uri":"http://localhost:PORT","token":"...",
 "endpoints":[{"method":"GET","path":"/sessions/___my_app_macos_macOS/logs",
   "url":"http://localhost:PORT/sessions/___my_app_macos_macOS/logs?token=..."}, ...]}
```

On stdout, the protocol stream starts with `daemon.connected` and then reports `app.start`, `app.started`, and the rest.

**What counts as protocol on stdout.** A line is a protocol message if and only if it is a `[{…}]` envelope. Anything else is passthrough output that a client should show to the user rather than parse. That is upstream's convention too, and it is what makes `bazel run` safe here: bazel forwards a successful action's stdout, so a run that first has to rebuild the tool prints a line like `Generated: /…/flutter_bazel` before the first envelope.

#### Endpoints

| Endpoint | Verb | Purpose |
|---|---|---|
| `/command?token=…` | `POST` | Run a protocol method against the session. Body: `{"method":"app.<X>", "params":{"appId":"…", …}}`. |
| `/commands?token=…` | `GET` | What this run can do right now: `{"protocolVersion", "commands":[{"name","longRunning"}]}`. |
| `/sessions/{appId}/logs?token=…` | `GET` | The app's console output, from a bounded ring buffer. |
| `/sessions/{appId}/screenshot/native?token=…` | `GET` | A PNG of the app as the platform sees it. Works on every device. `&screen=<id or name>` picks a screen of a device that has several; see [Screens](#screens). |
| `/sessions/{appId}/screens?token=…` | `GET` | The device's screens, and which one the app is on. |
| `/sessions/{appId}/screenshot/flutter?token=…` | `GET` | A PNG of the widget tree from the engine. Not available at the pinned Flutter; see below. |

The endpoints speak plain HTTP/1.1, so `curl -s "$URI/..."` works. If your `curl` tries HTTP/2 by default, add `--http1.1`.

#### Which commands are available

The set of commands is not fixed when a client connects. It grows through the run and describes this run rather than the tool. A web run gains `app.setViewport` once the browser is up and never offers `app.buildInfo`, because only a `-c dbg` native build carries the record that command reads. The widget-driving commands are offered once the tool knows the run carries the agent extensions, which is every native run, the DDC dev loop on the web, and any web bundle built in debug (`--wasm`, or `--no-hot -c dbg`). They answer once the app is reachable, which on the web and on an iPhone is well after `app.started`. `app.pressKey` is offered on every run, since a web bundle without the extensions can still take keys through the browser. So re-read `/commands` rather than caching the first answer. `longRunning` marks commands that rebuild or recompile before answering; those deserve a generous timeout and are the ones `app.progress` events are emitted for.

A `--machine` client does not need the endpoint. It receives the list in `daemon.connected` and again in every `daemon.commandsChanged`. `daemon.connected` also carries `protocolVersion`. The protocol stream is also the only place for things the channel cannot push: `app.devTools` carries the DevTools URL, `app.debugPort` the VM service's `port`, `wsUri`, and `baseUri`, `app.dtd` the Dart Tooling Daemon the app is registered with, and `app.webLaunchUrl` the address a web run is served at. The browser the tool launches uses a scratch profile and may be headless, so that URL is how you open the page in your own browser. The full event list is the header comment of `tools/dev_tool/lib/machine_protocol.dart`.

**Driving the browser yourself.** `app.webLaunchUrl` also carries the browser's DevTools protocol endpoint: `cdpPort`, and `webSocketDebuggerUrl` for the app's page. The same two fields are on the `web_app_url` log record, for a client reading stderr. Chrome picks the port, so nothing else tells you where it is. With it you can send your own `Input.dispatchKeyEvent`, `Runtime.evaluate` or trace. The page URL is the one listed when the browser came up. It survived a `--wasm` hot restart when we checked, but if it stops answering, re-read `http://127.0.0.1:<cdpPort>/json` and pick the `page` target on the app's origin, as the tool does before each of its own uses. Chrome takes several DevTools clients at once, so yours does not displace the tool's.

The commands, once the app is up:

- **Reading the screen:** `app.dumpSemanticsTree`, the whole accessibility tree in one answer. See [Reading the semantics tree](#reading-the-semantics-tree).
- **Widget driving:** `app.dumpWidgetTree`, `app.tap`, `app.longPress`, `app.doubleTap`, `app.drag`, `app.hover`, `app.hoverExit`, `app.setWindowActive`, `app.scrollIntoView`, `app.enterText`, `app.getText`, `app.getRect`, `app.waitFor`, `app.waitForAbsent`, `app.pageBack`, `app.settle`. These are served by extensions the app registers before `main()` on every launch, so they survive hot restart.
- **Keys:** `app.pressKey`, on every run, including `--profile` web runs. See [Pressing keys](#pressing-keys).
- **Lifecycle:** `app.hotReload`, `app.restart`, `app.stop`, `daemon.shutdown`. `app.restart` is upstream's `flutter run --machine` command: without `fullRestart` it is a hot reload, and `fullRestart: true` is the restart. It also accepts `pause`, `reason` and `debounce`. `reason` and `debounce` have no effect, since this tool already runs one reload or restart at a time; `pause: true` is refused, since the tool does not leave the isolate paused.
- **Run-specific:** `app.buildInfo` on native debug runs, `app.setViewport` on web runs.

**Hover, mouse presses and window focus.** `app.hover` moves a synthetic mouse over the widget a selector names (its centre) or to `x` and `y` in logical pixels, and `app.hoverExit` takes it off the app. Neither moves the system cursor's position, so the real mouse stays free. The mouse stays where it was left, as a real one does. `app.tap`, `app.longPress`, `app.doubleTap` and `app.drag` take `"pointer": "mouse"` to press from that mouse, with the primary button, instead of from a finger, so a widget sees hover and press together. All four also take `x` and `y` instead of a selector, and a mouse press with neither lands where the mouse already is: hover, then press. The `app.hover` reply carries `cursor`, the cursor the widget under the mouse asked for (`click`, `text`, and so on), so it can be checked without looking at the screen. The engine applies a hover's cursor to the host, so the tool puts the arrow straight back after each move, and the host's cursor is the arrow again by the time the reply comes; `app.hoverExit` puts it back too (`cursorRestored`). The host's cursor shape can still change for an instant, and a real pointer over the window gets its own shape at its next movement. A hover has no timer of its own: pass `"settle": "false"` and wait as long as the state you are reading needs, a tooltip's delay for one. `app.settle` and the wait after every command treat the app as idle when no frame is scheduled, as `pumpAndSettle` does, so a visible tooltip does not keep them from settling. `app.settle` answers `settled` as `yes`, `no` or `skipped`, with `settleDetail` when it is not `yes`, like every other command. `app.setWindowActive` with `"active": "true"` or `"false"` tells the framework the window is focused or not (`AppLifecycleState.resumed` or `inactive`) without changing the frontmost app. That is the framework's view only: the native window's key state is untouched, a real click or key in the window flips it back, and AppKit-drawn chrome such as the traffic lights does not follow. A macOS window with no title bar can never become key, so there it is the only way to see the active state.

`app.stop` stops the one app its `appId` names, as upstream's does. A run driving two devices carries on with the other. A bare `app.stop` with no `appId` is refused rather than read as "all of them". `daemon.shutdown` ends the run: every app, the browser, the compiler, and the tool itself.

An app that dies under a connected run ends the run too: the tool says why in the platform's words with the app's last output, exits with a failure status, and the `app.stop` event carries the reason in `error`, as upstream's does. An app that exits with code 0, one you stopped, or one closed on its device is not a failure: on the iOS Simulator, closing the app from the app switcher or with `xcrun simctl terminate` ends the run with status 0, while a crash fails it. `attach` is unchanged: it ends with status 0 when the app's VM service closes for good.

**A web bundle is driven through a page bridge, in debug builds only.** `--wasm` and `--no-hot -c dbg` serve a bundle built by dart2wasm or dart2js, which has no VM service: there `registerExtension` only fills a private table. A debug build therefore registers the agent extensions itself and installs a JavaScript bridge on the page, which the tool calls over the browser's DevTools protocol. The widget-driving commands work the same as on the DDC dev loop, including `app.dumpWidgetTree`. A `--profile` or release bundle compiles the extensions out, so the commands are absent from `/commands` rather than present and refusing, and the run says so once at startup as an `agent_surface_unavailable` log record. Such a run can still serve `app.pressKey`, `/logs`, `screenshot/native`, and `app.restart`. If a debug page never installs the bridge (a build from before it existed), a command fails after 30 seconds saying so. A page paused in the browser's own DevTools answers nothing until you resume it.

**Commands issued early wait.** `app.started` means `main()` has begun, which is what upstream's protocol means by it, and an app that has begun running has not built a widget tree yet. On `-d chrome` the gap is DWDS, which holds `main()` until the browser has connected. On an iPhone the gap is the app's own start, measured at 61 seconds after `app.started` for a debug build. A command sent in that window waits it out rather than failing, so you can fire on `app.started` without a readiness poll. The wait is reported as an `app.progress` pair — "Waiting for the app to render its first frame" opening it, and what the wait found closing it, so a client reading the stream can tell a frame that arrived from one that never did. The wait has no time limit: a first frame that lands late, on a loaded host say, makes the app drivable whenever it arrives, and while it waits the run logs a `first_frame_slow` warning and sends a "Still waiting" `app.progress` every thirty seconds on a host. It ends when the app paints, when the app exits (commands are then refused, saying it exited before rendering) or when the run ends. Waiting for a specific widget is still yours to ask for, with `app.waitFor`.

#### Reading the semantics tree

`app.dumpSemanticsTree` returns the app's accessibility tree as text: every node a screen reader would see, with its label, state, actions and where it is. It takes `appId` and nothing else, and answers `{"text": …}`, with `notRendering` when the app is not drawing frames and `frameMissed` when a frame pending at the time did not finish within 5 seconds, so the tree is from before it. It is the cheapest way to read a whole screen, and unlike a picture it says what each control is and where to tap it. Measured on `hello_world`: the dump is 1,135 bytes, which we estimate at 300 to 600 tokens. A screenshot costs, by Anthropic's published rule of width × height / 750 after scaling to fit 1568 pixels and 1.15 megapixels, about 670 tokens for the 800x632 macOS window at 1x and about 1,500 for the 1260x2736 iOS simulator or the 1080x2424 Pixel.

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.dumpSemanticsTree","params":{"appId":"'$APP'"}}' | jq -r .result.text
```

```
view 0 800x600 @1x
#3 scopesRoute @400,300 800x600
  #30 header "Hello World" @400,28 120x28
  #6 "count: 0" @400,254 56x20
  #7 button "Increment (agent)" [tap] @400,280 171x32
  #8 textField [tap] @400,320 200x48
  #27 [scrollUp] @400,444 200x80
    #13 "item 0" @400,416 200x24
    #17 hidden "item 4"
  #31 button tooltip="Increment" [tap] @756,556 56x56
```

Each view starts with a `view <id> <width>x<height> @<pixel ratio>x` line. Each node line is `#<id>`, then the node's role and flags, then its strings (`"label"`, `value=`, `hint=`, `tooltip=`, and `id=` for a `Semantics.identifier`), then its actions in brackets, then `@x,y`, the centre of the node in logical pixels, and its size. Indentation is nesting, and nodes come in the order a screen reader walks them. Flags are Flutter's names without `is` (`button`, `textField`, `header`, `obscured`, `readOnly`, `focused`), with each state pair folded into one word: `checked`, `unchecked` or `mixed`; `on` or `off`; `selected` on the one that is; `expanded` or `collapsed`; `disabled` for a control that is not enabled. `hidden` marks a node scrolled out of view. It has no `@` point, because its rect lies under whatever is drawn there: scroll it into view, then dump again.

Some nodes are left out. A node that carries nothing but its children is dropped and its children move up a level. A node merged into its parent is dropped too, because its text and actions are already on the parent's line, which is how a screen reader sees it. Actions every focusable node has (`focus`, `showOnScreen`, cursor movement) are not listed.

To act on a node, pass its point to the pointer commands: `app.tap` with `"x"` and `"y"` set to the `@` values. A node with a label can also be named with the `semanticsLabel` selector, for `getRect`, `waitFor` and the rest. To type into a field, tap it and then call `app.enterText` with no selector. Node ids are not selectors: they last only while the widget that produced the node does.

This is not Flutter's own `debugDumpSemanticsTree` text. That text gives each rect in its parent's coordinates, some behind a transform matrix, so it does not say where to tap, and on `hello_world` it is 8,198 bytes, seven times the size. Flutter still serves it through its `ext.flutter.debugDumpSemanticsTreeInTraversalOrder` extension, in DevTools or over the VM service, once semantics are on.

Semantics are off in a Flutter app until something asks for them. The first agent command of any kind turns them on and keeps them on until the app restarts, so the dump needs no setup step. The cost is the framework building the semantics tree for each frame that changes it, and the platform's accessibility layer receiving it, which is what any app pays while a screen reader runs. Every view the app's main isolate renders is listed. A window that runs its own engine, like the second window in `e2e/multi_window_example`, is a separate isolate the tool does not drive. Like the other agent commands, it is refused on a profile or release build, with the reason: the agent extensions are compiled into debug builds only.

#### Reading logs

`/logs` is polled with a cursor. There is no long-lived connection, and each call returns exactly what you ask for.

| `since` | Meaning |
|---|---|
| omitted | The last 200 lines. Use this when you have no cursor yet. |
| `-N` | The last `N` lines. |
| `0` | Everything still buffered, oldest first. |
| `N > 0` | Resume at line `N`. Feed back a previous `nextCursor`. |

`limit` caps the page, with a default and maximum of 500. A non-numeric `since` or a non-positive `limit` is a `400`, because a mistyped cursor would otherwise look like a working poll loop that re-reads the tail forever.

```sh
# Tail, then poll forward.
curl -s "$URI/sessions/$APP/logs?token=$T"
# {"lines":[{"index":812,"text":"flutter: meter -18dB","error":false}],
#  "nextCursor":813,"launch":1,"missed":0,"dropped":0,"closed":false}

curl -s "$URI/sessions/$APP/logs?token=$T&since=813"
```

The fields in the response:

- `error` marks lines that arrived on an error channel: the process's stderr, a VM service `Stderr` event, `console.error`. It is a channel, not a severity. Platforms that deliver the whole device log over one stream (iOS and Android) deliver engine `[ERROR:…]` lines with `error: false`, so match on the text if you care about those.
- `missed` is non-zero when the cursor you asked for had already been evicted, so a poller learns it has a gap instead of reading a short page as complete. `dropped` is the total evicted over the run.
- `closed` turns true once the app's output has ended, so a poll loop can stop. The buffer survives the app's exit, so a crashed app's final output is still readable.
- `launch` is which launch of the app the page came from: 1 for the original, one more per relaunch. Each launch buffers from zero, so when `launch` changes, drop your cursor and re-tail.

#### Screenshots

`screenshot/native` captures the app the way the platform sees it (`screencapture`, a read of the X display, `devicectl device capture screenshot` on the iOS simulator and iPhones, `adb screencap`, or the browser's own capture) and works on every device. `screenshot/flutter` asks the engine for the widget tree alone, with no window chrome, but the engine cannot produce it under Impeller and there is no engine screenshot on the web at all. Since Flutter 3.47 every platform renders with Impeller by default, so every device answers `501` naming `screenshot/native`. The tool does not try to detect an app that has turned Impeller off, because `screenshot/native` captures either way.

Both endpoints wait for the app to go idle before capturing, so a screenshot taken right after `app.tap` shows what the tap did. Without that wait you would get the frame from before the action painted, and a stale picture is indistinguishable from a feature that did not work. The response says what you got: `X-Settled: yes` means the app was idle first, `no` means the wait ran out or the app is backgrounded, and `skipped` means you passed `settle=false` or the run's app cannot be asked (a `--profile` or release web bundle). `X-Settle-Detail` carries the reason for anything but `yes`, percent-encoded so it can hold characters a header cannot; any URI-component decoder gives back the text. The wait is never fatal, since an app that cannot settle is the one whose picture you most want. `app.settle` is the same wait as a command, for use between two of your own.

##### Screens

A device draws to a *screen*, and most have one. An iPhone Duo simulator has two built-in screens and the app draws on the one its posture (folded, half open, open) turns on; an iPhone that is mirrored to a wireless display has a second, external one. `GET /sessions/{appId}/screens` lists them:

```json
{"screens": [
  {"id": "9552AE4F-…", "name": "LCD",   "type": "integrated", "width": 1398, "height": 2034, "active": true,  "primary": true},
  {"id": "40096A2C-…", "name": "LCD-1", "type": "integrated", "width": 2007, "height": 2853, "active": false, "primary": false}
]}
```

`active` says whether the app is on that screen now. It is `null` where the device does not say, which is every device with one screen. `type` is what the platform calls the screen: on iOS, Apple's display type (`integrated` for the device's own, `wireless`, `tvOut`, `carPlay`, …). An iOS screen with no unique id has the id `displayId:<n>`. A simulator's ids change on every boot, so read the list again rather than keeping one.

`screenshot/native` with no `screen` captures the screen the app is on:

- One built-in screen: that one. An external screen (`wireless` and the like) is never chosen without being named.
- Several built-in screens: the one with `active: true`. A simulator has not reported its posture for the first seconds after it boots; the request asks again until it has.
- Several active, none active, or no report within the bound: `422` with the screens listed in `error` and, as `screens`, in the body. The tool does not pick one.

`&screen=<id or name>` names a screen instead: its `id`, its `displayId:<n>`, or its `name`. An unknown name, or one that matches two screens, is the same `422`. An external screen is captured this way. An iOS screen with no unique id can only be captured as the primary one, and naming any other answers that it cannot be captured.

`screen` and `window` are different things. `screen` is a display the device has; `window` (macOS only) is one window an app has, matched by exact title, on that Mac's one screen. Giving `screen` to a device with one screen is allowed when it names that screen (`main` or the device's name).

A screenshot has one 30-second budget, once the app has drawn its first frame: listing the screens, waiting for a posture and the capture all spend from it, and the error for running out says which step was waiting.

On iOS this needs Xcode 27 or later (see [Requirements](#requirements)): the simulator and hardware both go through `devicectl device info displays` and `devicectl device capture screenshot`.

#### Driving widgets

Methods that target a widget (`tap`, `longPress`, `doubleTap`, `drag`, `getRect`, `getText`, `enterText`, `scrollIntoView`, `waitFor`, `waitForAbsent`) take exactly one selector, following `flutter_driver`'s finder vocabulary:

| Param | Matches |
|---|---|
| `key` | A widget whose `ValueKey` value equals the string. |
| `text` | A widget whose displayed text equals the string, read the way `getText` reads it: a `Text`, including a `Text.rich` by its spans' plain text, a `RichText`, or a text field's contents. |
| `tooltip` | A `Tooltip` whose `message` equals the string. |
| `type` | A widget whose runtime type name equals the string, for example `ElevatedButton`. |
| `semanticsLabel` | A widget whose semantics label equals the string. |

Zero selectors or more than one is refused with a `422` (see [How a command says no](#how-a-command-says-no)). Other params: `durationMs` (longPress, drag, scrollIntoView), `dx` and `dy` (drag, scrollIntoView), `scrollableKey` (scrollIntoView, `ValueKey` only), `timeoutMs`, `settle`, `requireHit`.

Put the `Key` on the widget you would point at, such as the `Chip`, the `ListTile`, or the button, rather than on the `Text` it builds. A selector reaches the same distance for every method.

- **`getText`** returns the text of the first text-bearing descendant of the match, in pre-order (`Text` including `Text.rich`, `RichText`, `EditableText`), and lists all of them in `texts`, so a container with two strings shows as two: `{"text":"Increment","texts":["Increment"]}`.
- **`enterText`** takes `text` as the string to type, which is why it is the one method that does not accept the `text` selector. With a selector it focuses the first `EditableText` under the match and types into it, with no preceding tap needed, and reports what it typed into: `{"enteredText":"hi","into":"ValueKey(emailField)"}`. With no selector it types into whatever is focused, reporting `"into":"focused"`.

**Settling.** After dispatching input, a method waits until the app is idle before returning, so a follow-up `getRect` or `getText` sees the post-action layout. The wait is bounded by `timeoutMs`, default 10000. Every input command's reply says how that wait ended, in `settled`: `yes`, `no`, or `skipped` (for `settle: "false"`, or an app that is backgrounded). These are the values `app.pressKey`'s browser route and the screenshot headers use. When it is not `yes`, `settleDetail` says why. A wait that runs out is `no` on an otherwise successful reply, not an error. The input was delivered before the wait began, so do not send the command again, or it taps twice. `settleDetail` gives the number of animations still running; zero means the app was backgrounded mid-command. An app that was already backgrounded returns immediately, because backgrounding is what stops frames, so there is nothing to wait for. On macOS a window that has been in front and is then hidden, or fully covered by another app's window, counts as backgrounded; one that was covered from the moment it opened keeps drawing, because the embedder reacts only to a change.

**A backgrounded app takes input, and shows nothing.** An app the OS has backgrounded stops producing frames: a locked screen on a device, or on macOS a window hidden or covered after it had been in front. Input still lands and its handler still runs, but nothing rebuilds, so a `getText` straight afterwards answers with the tree as it was and not with what your tap changed. Every input command says so in that state, with a `notRendering` field on an otherwise successful reply, and so do `app.getText`, `app.getRect`, `app.waitFor` and `app.waitForAbsent`. When one of those finds nothing, its error carries the same note. That matters most after a restart in that state, when the tree holds only what `runApp`'s first frame built, and a widget the app shows once its data loads is not there yet. On a locked Pixel this looked like a tap that did nothing; the value appears when the device is unlocked.

Some apps never go idle: a spinner, a progress indicator, any perpetual `AnimationController` keeps a frame callback pending for as long as it runs, so every command against such an app spends its whole timeout before answering `settled: "no"`. `settle: "false"` turns the wait off for one command, the equivalent of `flutter_driver`'s `runUnsynchronized`. What you give up is the guarantee: an immediate `getText` after an unsynchronised `tap` races the rebuild and reads the old value about half the time, so resynchronise with `app.waitFor` on the value you expect. `settle` accepts only `"true"` and `"false"`, because a typo would otherwise choose the opposite behaviour in silence.

**Reaching the widget.** Being in the tree is not the same as being where a pointer can land. A child of a scroll view that is scrolled off screen is laid out outside the viewport, and a widget behind a dialog is covered. A selector still finds it and it still has a rect, so `tap`, `longPress`, `doubleTap`, and `drag` hit-test the point first and refuse when nothing there resolves to the target. The refusal says which case it is and what to do: scroll it into view, or move what covers it. This is `WidgetController`'s `warnIfMissed` with the fatal choice made, on the view that a success response for an event nobody received is worse than an error. `requireHit: "false"` dispatches at the point anyway, for a caller who means it.

`app.scrollIntoView` is the way through, and its `reachable` field answers whether a tap would now land. `iterations` counts drag-scrolls of a lazy list; `0` means the target was already built and `Scrollable.ensureVisible` was used.

#### Pressing keys

`app.pressKey` presses one key, or one key with modifiers held, in whatever has focus:

```sh
curl -s -X POST "$URI/command?token=$T" \
  -d '{"method":"app.pressKey","params":{"appId":"'$APP'","key":"Control+K"}}'
```

Keys are named the way Playwright's `keyboard.press` names them, since that is what agents already know: a character (`a`, `A`, `!`), a `KeyboardEvent` key or code (`Enter`, `Tab`, `Backspace`, `ArrowDown`, `Escape`, `KeyA`, `Digit1`, `Space`), and modifiers joined with `+` (`Control+K`, `Shift+Tab`, `Meta+A`). `ControlOrMeta` is Meta on Apple platforms and Control elsewhere. An unknown name is refused by name, with the spelling it probably meant: `Ctrl` gets "did you mean `Control`". Two Playwright details carry over: a single character is case-sensitive, and `Shift+a` types `a`, so write `A` or `Shift+KeyA` for a capital. One difference: only modifiers can be held, so `a+b` is refused. Send one command per key.

It takes no selector. Focus the field first, with `app.tap` on it or by pressing `Tab`.

How the key reaches the app depends on the device, and the reply names the route in `route`:

| `route` | Devices | What happens | What it reaches |
|---|---|---|---|
| `browser` | Chrome: the DDC dev loop, `--wasm`, `--profile` | Real, trusted input sent to the app's page over the DevTools protocol (`Input.dispatchKeyEvent`). | What a keyboard reaches in that browser: the browser's own text editing, and the key events Flutter's web engine sees. |
| `framework` | macOS, iOS, Android, Linux, Windows | Simulated inside the app, modeled on `flutter_test`'s key simulator: each key as a `ui.KeyData` plus the legacy `flutter/keyevent` message the engine sends. A key the framework leaves unhandled then goes where the platform's input method would take it: typed text into the focused field, Return to the field's action (which is what fires `onSubmitted`), and on macOS the Cocoa editing selectors AppKit would produce, sent as `TextInputClient.performSelectors`. | Shortcuts, focus traversal and text editing. Not the OS and not its input method: IMEs, dead keys, system shortcuts and OS key remapping are never involved. |

A pass on the framework route is not evidence about OS-level input, which is why every reply says which route ran.

The reply also says what was sent:

- **browser:** `sent` is the CDP events, in order. `focus` is what had the browser's focus, as tag names through shadow roots; a focused Flutter text field reads `flutter-view > input`. When the key types text and the focus is not in a text field, `warning` says the text reached nothing.
- **framework:** `sent` lists each key event and whether the framework handled it, `handled` is the answer for the main key, and `textInput` is what went to the field: `{"inserted":"a"}`, `{"selectors":["moveDown:"]}`, `{"action":"TextInputAction.done"}`, or `{"skipped":"<why>"}`. On desktop, a key pressed while the app's window is not the focused one, because another app is in front or after `app.setWindowActive` with `"false"`, or while the window is hidden or covered by another window, first makes the app active, as a real key press would find it: the framework had taken focus off the field while the window was inactive or hidden, and gets it back. `activated` says this happened. The real window stays where it is.

```json
{"route":"framework","key":"ArrowDown","handled":false,
 "sent":[{"type":"down","key":"Arrow Down","handled":false},{"type":"up","key":"Arrow Down"}],
 "textInput":{"selectors":["moveDown:"]}}
```

**Mac editing keys in a browser.** On a Mac, a browser edits text through the Cocoa command AppKit attaches to a key, and CDP input enters below AppKit. So the browser route attaches the command a Mac would, from Playwright's `macEditingCommands` table. We measured the difference on a Flutter web text field: `Control+K` deletes to the end of the line only when it carries `deleteToEndOfParagraph`, while Backspace, the arrow keys and Enter worked with or without their commands. Enter carries `insertNewline` anyway, and in a textarea it inserted exactly one newline either way.

**Waiting.** Both routes wait for the app to go idle before answering, with the same `timeoutMs` and `settle` as the other input commands, and report how the wait ended in `settled` and `settleDetail`: `yes`, `no` or `skipped`, the values the screenshot headers use. The browser route can ask on every run that offers the agent surface: the DDC dev loop and debug `--wasm` bundles. The keys were delivered in every case. A `--profile` run cannot be asked, so it answers `skipped`; take a screenshot to see what the key did. A page in a hidden, minimized or covered window draws no frames, so the key's effect does not show until the page is visible again. The reply says `no` with that reason, and `--web-run-headless` avoids the problem.

#### Reload and restart responses

A reload or restart that landed in an app that is not drawing says so. The app is running the new code, so `succeeded` is `true`, and `notShown` says, per app, why the screen does not show it yet:

```json
{"succeeded":true,"runningCode":"updated",
 "notShown":{"<appId>":"the app is not drawing, because the OS reports it cannot be seen (lifecycle state \"hidden\": …). It shows the change once it can be seen again"},
 "message":"Restart successful, but the app is not drawing, because the OS reports it cannot be seen …"}
```

The reply comes as soon as the app has built its first frame and said it cannot draw, rather than after the ten seconds the tool gives a frame to arrive. On the macOS plugin example, restarts into a window hidden after it had been in front took 11.3 s before this and 1.4 s after. An app that neither draws nor says why, such as one attached to without the rules' agent extensions, still gets the ten seconds, and `notShown` then says only that no frame came.

A restart that relaunched the process because a native library changed says so:

```json
{"succeeded":true,"runningCode":"updated","relaunched":true,
 "nativeLibsChanged":["…/libmul.dylib"],"launch":{"<appId>":2},"ready":true,
 "message":"Restart successful — the app was relaunched because its native libraries changed (…). …"}
```

`ready` says the relaunched app rendered a first frame before the response returned, so its extensions are registered and the next `app.*` call will land. `false` means that wait timed out, not that the app is broken. The protocol stream re-emits `app.debugPort` and `app.started` for the new process.

A reload after a native rebuild, with the bindings unchanged, delivers the edit and reports the stale library:

```json
{"succeeded":true,"runningCode":"updated",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload successful. …/libbridge.dylib was rebuilt and its bindings did not change, so the increment is live over the library the app already loaded — the new native code is not running. A restart (R, or `app.restart`) delivers it: it relaunches the app when the native code the app runs differs from what the tree builds, and otherwise restarts it in place."}
```

With the bindings changed, or nothing declaring them, the edit is withheld:

```json
{"succeeded":false,"runningCode":"unchanged",
 "nativeLibsStale":["…/libbridge.dylib"],
 "message":"Hot reload withheld: …/libbridge.dylib changed, and so did what its bindings are generated from …"}
```

Nothing is compiled and nothing is sent, so the app keeps the code and the library it launched with, and `app.restart` with `fullRestart: true` picks up the new one. An `attach` run cannot replace a process it did not start, so there the reply says to launch the app again and attach to it instead. `nativeLibsStale` means the same thing in both replies, and `succeeded` says whether the edit landed. The check costs no Bazel of its own: a `stat` per declared file, and a content hash only for a file the build rewrote.

A reload that patched native code into the app says what it patched, and `nativeReverted` lists libraries sent back to their launched code:

```json
{"succeeded":true,"runningCode":"updated",
 "nativePatched":{"libmul.dylib":["mul_body"]},
 "message":"Hot reload successful. Patched libmul.dylib in the running app (mul_body)"}
```

A patch that cannot be delivered withholds the reload with the patch builder's reasons in `nativePatchRestart`, and one that did not load names the apps in `nativePatchFailed` and `nativePatchApplied`.

#### How a command says no

Every failure, on either transport, is a top-level `error` carrying the reason. Over HTTP the status says which kind: `404` the command or app does not exist here, `400` the tool could not read the request (not JSON, no `method`, `app.pressKey` without `key`), `501` this run cannot serve it (an engine screenshot under Impeller), `422` it was asked and could not be done (the app refused, or never answered). The app checks a widget command's own parameters, so a missing selector or two selectors is a `422` carrying the app's reason, not a `400`. A `500` means the tool itself broke, which is the one case worth retrying or reporting. On the stdin protocol the same failure is upstream's `{"id":…, "error":"<reason>"}`.

An outcome that carries its own verdict stays inside `result`. A hot reload that ran and failed answers `{"succeeded":false, "error":…}`, because it ran and reported a failure rather than refusing to run.

### Working with a coding agent

The control channel is what lets a coding agent such as Claude Code check its own work: it can reload the app after an edit, read text back, and look at a screenshot rather than guessing from the code.

**The skill.** This repository ships a skill, `flutter-bazel`, that teaches an agent the whole loop: starting a session, finding the channel, reading the UI, driving it, reloading, and reading failures. For Claude Code it is a plugin in this repository's marketplace:

```sh
claude plugin marketplace add aran/rules_flutter
claude plugin install rules-flutter@rules-flutter
```

Or, inside a session, `/plugin marketplace add aran/rules_flutter` and then `/plugin install rules-flutter@rules-flutter`. The skill itself is in the open Agent Skills format, in [`agent_plugin/skills/flutter-bazel`](agent_plugin/skills/flutter-bazel/SKILL.md), so an agent that reads that format can use the same directory.

With the skill or without it, three choices make the loop work well.

**Start the app in machine mode, in the background.** The run lives for the whole session, so start it once and send its output to files. `--machine` keeps stdout to protocol events, `LOG_FORMAT=json` makes the channel record on stderr one parseable line, and `--no-devtools` skips starting a DevTools server nobody will open. On the web, add `--web-run-headless`.

```sh
LOG_FORMAT=json fl run -t //:my_app_macos -d macos --machine --no-devtools \
  > /tmp/app.out 2> /tmp/app.err &
```

The agent reads the URL and token from the `http_control_channel` line in the stderr file, and waits for `app.started` in the stdout file before sending commands.

**Choose a watch strategy.** In terminal mode the tool reloads on every save. In machine mode watching is off by default, and that is the better setting for an agent. An agent edits several files in a row, and a reload after each save would compile half-finished changes. Have the agent call `app.hotReload` itself when it is done editing. The reply says whether the reload landed and which files were recompiled, which is exactly the evidence the agent should be reporting. If the agent needs watch mode anyway, pass `--watch` and have it call `app.settle` before reading anything back.

**Ask for screenshots before and after every change.** An agent that edits code without looking at the result will happily report success on a blank screen. Put the rule in the file your agent reads at startup, such as `CLAUDE.md` or `AGENTS.md`:

```markdown
## Running the app

Start the app once per session, in the background, and keep it running:

    LOG_FORMAT=json fl run -t //:my_app_macos -d macos --machine --no-devtools \
      > /tmp/app.out 2> /tmp/app.err &

The control channel URL and token are on the `http_control_channel` line of
/tmp/app.err. Wait for an `app.started` event in /tmp/app.out before driving
the app. The `appId` is in that event.

## Every code change

1. Before editing, save a screenshot: GET /sessions/<appId>/screenshot/native.
2. Edit, then reload: POST /command with
   {"method":"app.hotReload","params":{"appId":"<appId>"}}.
   Use app.restart with "fullRestart":true instead when the change touches main() or startup code.
   Read `succeeded` from the reply. A reload that fails is not done.
3. After the reload, save a second screenshot and compare it with the first.
   Say in your report what changed on screen, not just what changed in code.
   A reply with `notShown`, or a read with `notRendering`, means the window
   is hidden or covered: bring it to the front before trusting the screen.
4. Check GET /sessions/<appId>/logs for exceptions before moving on.

Stop the app with daemon.shutdown at the end of the session.
```

Adjust the target and device to your project. With the long form of the command in place of `fl`, this works without bazel_env. The screenshot endpoint waits for the app to settle, so a capture taken straight after a tap or a reload shows the result; see [Screenshots](#screenshots).

**Flutter's own agent tools find the app too.** Like `flutter run`, a run starts a Dart Tooling Daemon (DTD) and registers each app's VM service with it. So the Dart MCP server (`dart mcp-server`) and other DTD clients find a `flutter_bazel` run the way they find a `flutter run` one: `dart tooling-daemon --list` lists the run's DTD, and the server's `list_running_apps` and `dtd` tools show the app. Its `hot_reload` and `hot_restart` go through the tool's own reload, so they recompile with Bazel like `app.hotReload` does, and `get_runtime_errors` reads the app's errors. A `--machine` client gets the DTD's address from the `app.dtd` event; in a terminal, `--print-dtd` prints it. The DTD stops when the run ends. Use the MCP server only for these running-app tools: its `run_tests`, `launch_app` and `pub` use the machine's Flutter, not the one the workspace builds with.

## Examples

The `e2e/` directory holds working workspaces, each with its own tests:

| Directory | What it shows |
|---|---|
| `e2e/smoke` | The smallest possible toolchain check. |
| `e2e/hello_world` | A minimal app on every platform: kernel, AOT, assets, macOS, iOS, Android, Linux, Windows, and web. |
| `e2e/codegen` | Per-file and aggregate code generation, generated code in dependency packages, and hot reload over generated sources. |
| `e2e/ffi_example` | Native code as Dart Native Assets and as `native_deps`, side by side. |
| `e2e/ffi_plugin_example` | A `flutter_plugin` with a Dart plugin class and `native_deps`. |
| `e2e/plugin_example` | Pub plugins from the hub, and a `flutter_plugin` with a Dart plugin class only. |
| `e2e/macos_example` | A full macOS app with bundle structure checks. |
| `e2e/ios_example` | An iOS app. Requires Xcode. |
| `e2e/android_example` | An Android APK built three ways, with APK content checks. |
| `e2e/linux_example` | A Linux app built three ways, with bundle checks. |
| `e2e/windows_example` | A Windows app built three ways, with bundle checks. |
| `e2e/web_example` | WASM-with-JavaScript-fallback, WASM-only and JavaScript web builds with `web_assets`, and a WASM-only app dart2js cannot compile. |
| `e2e/cross_compile_example` | A Linux bundle cross-compiled from macOS. |
| `e2e/multi_window_example` | Multi-window macOS and multi-scene iOS with `FlutterEngineGroup`. |
| `e2e/dual_hub` | Two pub hubs in one workspace that differ on a package version: one repository per package, at the higher version. |

[docs/TESTING.md](docs/TESTING.md) describes how the repository itself is tested, including the manual checks that need a display or a device.

## License

See [LICENSE](LICENSE).
