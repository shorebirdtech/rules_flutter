"""The desktop runners link what the pub plugins' CMake builds link.

`url_launcher_windows` declares `target_link_libraries(... shlwapi.lib)` in its
`windows/CMakeLists.txt`; without it the Windows runner fails to link with
`LNK2019 unresolved external symbol __imp_UrlUnescapeA`. The application
collects its plugins' link libraries from the pub packages as fetched, so this
reads them from the real `url_launcher_windows` and `url_launcher_linux`, on
whatever host runs the analysis.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_flutter//flutter:providers.bzl", "FlutterApplicationInfo")

def _libraries(env):
    info = analysistest.target_under_test(env)[FlutterApplicationInfo]
    return struct(
        windows = info.windows_plugin_libraries.to_list(),
        linux = info.linux_plugin_libraries.to_list(),
    )

def _link_libraries_impl(ctx):
    env = analysistest.begin(ctx)
    libs = _libraries(env)

    by_package = {lib.package: lib for lib in libs.windows}
    asserts.true(env, "url_launcher_windows" in by_package, "no url_launcher_windows in %s" % by_package.keys())
    windows = by_package["url_launcher_windows"]
    asserts.equals(env, ["shlwapi.lib"], windows.linkopts)
    asserts.equals(env, [], windows.link_errors)

    # Every plugin of the app is readable: none leaves an error for the runner.
    for lib in libs.windows + libs.linux:
        asserts.equals(env, [], lib.link_errors, "%s: %s" % (lib.package, lib.link_errors))

    # url_launcher_linux links only what the runner already does.
    linux = {lib.package: lib for lib in libs.linux}
    asserts.true(env, "url_launcher_linux" in linux, "no url_launcher_linux in %s" % linux.keys())
    asserts.equals(env, [], linux["url_launcher_linux"].linkopts)
    return analysistest.end(env)

desktop_link_libraries_test = analysistest.make(_link_libraries_impl)
