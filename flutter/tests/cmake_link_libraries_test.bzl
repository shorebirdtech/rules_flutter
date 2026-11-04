"""Unit tests for cmake_link_libraries.bzl."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:cmake_link_libraries.bzl",
    "parse_cmake_link_libraries",
    "scan_cmake_commands",
)

# url_launcher_windows 3.1.6's windows/CMakeLists.txt, trimmed to the parts that
# matter: the plugin's own link call, then a test target that links more.
_URL_LAUNCHER_WINDOWS = """
cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "url_launcher_windows")
project(${PROJECT_NAME} LANGUAGES CXX)
set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "include/url_launcher_windows/url_launcher_windows.h"
  "url_launcher_windows.cpp"
  ${PLUGIN_SOURCES}
)
apply_standard_settings(${PLUGIN_NAME})
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin shlwapi.lib)

if (${include_${PROJECT_NAME}_tests})
set(TEST_RUNNER "${PROJECT_NAME}_test")
include(FetchContent)
FetchContent_MakeAvailable(googletest)
add_executable(${TEST_RUNNER} test/url_launcher_windows_test.cpp)
target_link_libraries(${TEST_RUNNER} PRIVATE flutter_wrapper_plugin shlwapi.lib)
target_link_libraries(${TEST_RUNNER} PRIVATE gtest_main gmock)
endif()
"""

# url_launcher_linux's linux/CMakeLists.txt, trimmed.
_URL_LAUNCHER_LINUX = """
set(PLUGIN_NAME "url_launcher_linux_plugin")
add_library(${PLUGIN_NAME} SHARED "url_launcher_plugin.cc")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
"""

def _windows(content):
    return parse_cmake_link_libraries(content, "windows", "windows/CMakeLists.txt")

def _linux(content):
    return parse_cmake_link_libraries(content, "linux", "linux/CMakeLists.txt")

def _url_launcher_windows_test_impl(ctx):
    env = unittest.begin(ctx)
    r = _windows(_URL_LAUNCHER_WINDOWS)
    asserts.equals(env, ["shlwapi.lib"], r.linkopts)
    asserts.equals(env, [], r.errors)
    return unittest.end(env)

url_launcher_windows_test = unittest.make(_url_launcher_windows_test_impl)

def _url_launcher_linux_test_impl(ctx):
    env = unittest.begin(ctx)
    r = _linux(_URL_LAUNCHER_LINUX)
    asserts.equals(env, [], r.linkopts)
    asserts.equals(env, [], r.errors)
    return unittest.end(env)

url_launcher_linux_test = unittest.make(_url_launcher_linux_test_impl)

def _names_test_impl(ctx):
    env = unittest.begin(ctx)

    # Bare names get the platform's library spelling; duplicates differing only
    # in case collapse, as the Windows linker treats them.
    r = _windows("""
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE shlwapi dwmapi.lib PUBLIC Shlwapi.lib "ws2_32")
target_link_libraries(p INTERFACE flutter)
""")
    asserts.equals(env, ["shlwapi.lib", "dwmapi.lib", "ws2_32.lib"], r.linkopts)
    asserts.equals(env, [], r.errors)

    r = _linux("""
add_library(p SHARED a.cc)
target_link_libraries(p PRIVATE flutter PkgConfig::GTK m pthread stdc++ m)
""")
    asserts.equals(env, ["-lm", "-lpthread", "-lstdc++"], r.linkopts)
    asserts.equals(env, [], r.errors)
    return unittest.end(env)

names_test = unittest.make(_names_test_impl)

def _syntax_test_impl(ctx):
    env = unittest.begin(ctx)

    # Comments, multi-line calls, case-insensitive command names and a link call
    # spread over lines are all read; a commented-out call is not.
    r = _windows("""
# target_link_libraries(p PRIVATE nothing.lib)
#[[ target_link_libraries(p PRIVATE block.lib) ]]
ADD_LIBRARY(p SHARED # the plugin
  a.cpp)
Target_Link_Libraries(p
  PRIVATE  # comment inside
    flutter
    first.lib   second.lib
)
target_link_libraries(p PRIVATE [=[third.lib]=])
""")
    asserts.equals(env, ["first.lib", "second.lib", "third.lib"], r.linkopts)
    asserts.equals(env, [], r.errors)

    # The plugin library is the first SHARED one, not a helper defined before it.
    r = _windows("""
add_library(helper STATIC h.cpp)
target_link_libraries(helper PRIVATE helper.lib)
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE p.lib)
""")
    asserts.equals(env, ["p.lib"], r.linkopts)
    asserts.equals(env, [], r.errors)

    # No library, no link call: nothing to add and nothing wrong.
    asserts.equals(env, ([], []), (_windows("").linkopts, _windows("").errors))
    r = _windows("project(x)\nadd_library(p SHARED a.cpp)\n")
    asserts.equals(env, ([], []), (r.linkopts, r.errors))
    return unittest.end(env)

syntax_test = unittest.make(_syntax_test_impl)

def _commands_test_impl(ctx):
    env = unittest.begin(ctx)
    commands = scan_cmake_commands("""if(A)
  foo("a b" (c d) [[e]])
endif()
bar()
""")
    asserts.equals(env, ["if", "foo", "endif", "bar"], [c.name for c in commands])
    asserts.equals(env, [1, 2, 3, 4], [c.line for c in commands])
    asserts.equals(env, [0, 1, 0, 0], [c.depth for c in commands])
    asserts.equals(
        env,
        ["a b", "(", "c", "d", ")", "e"],
        [a.text for a in commands[1].args],
    )
    return unittest.end(env)

commands_test = unittest.make(_commands_test_impl)

# record_windows 1.0.7's windows/CMakeLists.txt, trimmed.
_RECORD_WINDOWS = """
set(PLUGIN_NAME "record_windows_plugin")
list(APPEND PLUGIN_SOURCES "record_windows_plugin.cpp")
add_library(${PLUGIN_NAME} SHARED "record_windows_plugin_c_api.cpp" ${PLUGIN_SOURCES})

set(wmf_libs dxva2.lib evr.lib mf.lib mfplat.lib mfplay.lib mfreadwrite.lib mfuuid.lib Shlwapi.lib)

apply_standard_settings(${PLUGIN_NAME})
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin ${wmf_libs})
"""

def _variables_test_impl(ctx):
    env = unittest.begin(ctx)

    r = _windows(_RECORD_WINDOWS)
    asserts.equals(env, [
        "dxva2.lib",
        "evr.lib",
        "mf.lib",
        "mfplat.lib",
        "mfplay.lib",
        "mfreadwrite.lib",
        "mfuuid.lib",
        "Shlwapi.lib",
    ], r.linkopts)
    asserts.equals(env, [], r.errors)

    # Values go through the same rules as written ones: bare names get their
    # spelling, a value that cannot be translated is reported with the variable
    # and the line of the call, and the others still link.
    r = _windows("""
set(libs ws2_32 crypto::lib ok.lib)
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE ${libs} more.lib)
""")
    asserts.equals(env, ["ws2_32.lib", "ok.lib", "more.lib"], r.linkopts)
    asserts.equals(env, ["windows/CMakeLists.txt:4: `crypto::lib` is an imported CMake target (from ${libs})"], r.errors)

    # Linux reads them the same way.
    r = _linux("""
set(sys_libs m pthread)
add_library(p SHARED a.cc)
target_link_libraries(p PRIVATE flutter PkgConfig::GTK ${sys_libs})
""")
    asserts.equals(env, ["-lm", "-lpthread"], r.linkopts)
    asserts.equals(env, [], r.errors)
    return unittest.end(env)

variables_test = unittest.make(_variables_test_impl)

def _unsettled_variables_test_impl(ctx):
    env = unittest.begin(ctx)
    call = "add_library(p SHARED a.cpp)\ntarget_link_libraries(p PRIVATE ${libs})\n"
    unresolved = [
        "windows/CMakeLists.txt:%d: `${libs}` is a CMake variable that this file does not set once, outside any block, to literal values before this call",
    ]

    # Each of these leaves the variable unresolved: the call reports it, and
    # nothing is linked from it.
    for head, line in [
        # In a block.
        ("if(MSVC)\n  set(libs a.lib)\nendif()\n", 5),
        ("function(f)\n  set(libs a.lib)\nendfunction()\n", 5),
        ("foreach(x a b)\n  set(libs a.lib)\nendforeach()\n", 5),
        # Set twice, or changed after it is set.
        ("set(libs a.lib)\nset(libs b.lib)\n", 4),
        ("set(libs a.lib)\nlist(APPEND libs b.lib)\n", 4),
        ("set(libs a.lib)\nunset(libs)\n", 4),
        # Values that are not literal.
        ("set(libs ${other})\n", 3),
        ("set(libs a.lib $<$<CONFIG:Debug>:b.lib>)\n", 3),
        ("set(libs \"a.lib;b.lib\")\n", 3),
        ("set(libs)\n", 3),
        ("set(libs \"\")\n", 3),
        # Not the file's own variable.
        ("set(libs a.lib CACHE STRING \"\")\n", 3),
        ("set(libs a.lib PARENT_SCOPE)\n", 3),
    ]:
        r = _windows(head + call)
        asserts.equals(env, [], r.linkopts, head)
        asserts.equals(env, [unresolved[0] % line], r.errors, head)
    return unittest.end(env)

unsettled_variables_test = unittest.make(_unsettled_variables_test_impl)

def _errors_test_impl(ctx):
    env = unittest.begin(ctx)

    # A variable the file does not settle by itself, or after the call.
    r = _windows("""
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE flutter ${FLUTTER_LIBRARY} ${later} "${quoted}")
set(later x.lib)
set(quoted y.lib)
""")
    asserts.equals(env, [], r.linkopts)
    asserts.equals(env, [
        "windows/CMakeLists.txt:3: `${FLUTTER_LIBRARY}` is a CMake variable that this file does not set once, outside any block, to literal values before this call",
        "windows/CMakeLists.txt:3: `${later}` is a CMake variable that this file does not set once, outside any block, to literal values before this call",
        "windows/CMakeLists.txt:3: `${quoted}` is a CMake variable that this file does not set once, outside any block, to literal values before this call",
    ], r.errors)

    # Libraries before an unreadable one are still reported, with the line of
    # each call.
    r = _windows("""
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE good.lib $<$<CONFIG:Debug>:dbg.lib>)
target_link_libraries(p PRIVATE crypto::lib)
target_link_libraries(p PRIVATE -lfoo C:/libs/x.lib dir/y.lib "a;b" debug d.lib)
""")
    asserts.equals(env, ["good.lib"], r.linkopts)
    asserts.equals(env, [
        "windows/CMakeLists.txt:3: `$<$<CONFIG:Debug>:dbg.lib>` is a generator expression or contains a variable",
        "windows/CMakeLists.txt:4: `crypto::lib` is an imported CMake target",
        "windows/CMakeLists.txt:5: `-lfoo` is a linker flag",
        "windows/CMakeLists.txt:5: `C:/libs/x.lib` is a path",
        "windows/CMakeLists.txt:5: `dir/y.lib` is a path",
        "windows/CMakeLists.txt:5: `a;b` is not a single library name",
        "windows/CMakeLists.txt:5: `debug` makes the next library depend on the build mode",
    ], r.errors)

    # Targets: one the file defines, one a subdirectory or fetched project may
    # define, and the Flutter template's other targets. Named `.lib` files are
    # libraries whatever else the file does.
    r = _windows("""
add_subdirectory(third_party)
add_library(helper STATIC h.cpp)
add_library(p SHARED a.cpp)
target_link_libraries(p PRIVATE helper crypto flutter_wrapper_app shlwapi.lib)
""")
    asserts.equals(env, ["shlwapi.lib"], r.linkopts)
    asserts.equals(env, [
        "windows/CMakeLists.txt:5: `helper` is a CMake target this file defines",
        "windows/CMakeLists.txt:5: `crypto` may be a target of a subdirectory or fetched project",
        "windows/CMakeLists.txt:5: `flutter_wrapper_app` is a Flutter template target rules_flutter does not provide",
    ], r.errors)

    # Conditional calls cannot be evaluated; their libraries are not guessed.
    r = _windows("""
add_library(p SHARED a.cpp)
if(MSVC)
  target_link_libraries(p PRIVATE msvc.lib)
endif()
target_link_libraries(p PRIVATE after.lib)
""")
    asserts.equals(env, ["after.lib"], r.linkopts)
    asserts.equals(env, ["windows/CMakeLists.txt:4: target_link_libraries is inside an if(), foreach() or function() block"], r.errors)

    # The GTK imported target is the runner's; any other is not.
    r = _linux("""
add_library(p SHARED a.cc)
target_link_libraries(p PRIVATE flutter PkgConfig::GTK PkgConfig::LIBSECRET libfoo.so)
""")
    asserts.equals(env, [], r.linkopts)
    asserts.equals(env, [
        "linux/CMakeLists.txt:3: `PkgConfig::LIBSECRET` is an imported CMake target",
        "linux/CMakeLists.txt:3: `libfoo.so` is not a plain library name",
    ], r.errors)

    # flutter_wrapper_plugin is the Windows template's; Linux has no such target.
    r = _linux("add_library(p SHARED a.cc)\ntarget_link_libraries(p PRIVATE flutter_wrapper_plugin)\n")
    asserts.equals(env, 1, len(r.errors))
    return unittest.end(env)

errors_test = unittest.make(_errors_test_impl)

def cmake_link_libraries_test_suite(name):
    unittest.suite(
        name,
        url_launcher_windows_test,
        url_launcher_linux_test,
        names_test,
        syntax_test,
        commands_test,
        variables_test,
        unsettled_variables_test,
        errors_test,
    )
