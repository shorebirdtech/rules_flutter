"""The provisioning profile a device build of an e2e example is signed with."""

def _unset_impl(ctx):
    fail(
        "\n\nThis target is signed for a physical device and needs your own " +
        "provisioning profile, which this repository does not carry.\n\n" +
        "Set it up once:\n" +
        "  1. cp -r device.example device\n" +
        "  2. mv device/BUILD.bazel.example device/BUILD.bazel, then edit it " +
        "(device/BUILD.bazel explains how)\n" +
        "  3. echo 'common --{flag}=//device:profile' >> .bazelrc.user\n\n".format(
            flag = ctx.attr.flag,
        ),
    )

_device_profile_unset = rule(
    implementation = _unset_impl,
    attrs = {"flag": attr.string(mandatory = True)},
    doc = "Fails analysis, saying how to set up the device profile.",
)

def device_profile(name = "device_profile"):
    """Declares the label flag a device build takes its provisioning profile from.

    The flag's default fails analysis with the setup steps. A checked-in
    `provisioning_profile = "//device:profile"` would instead name a package
    that a fresh clone lacks (it is git-ignored and per developer), and
    `bazel query 'deps(//...)'` follows even a `manual` target's labels into
    it. A developer points the flag at the real profile in `.bazelrc.user`.

    Args:
        name: The flag's name; the package it is declared in is part of the
            flag the setup message tells the developer to set.
    """
    unset = name + "_unset"
    _device_profile_unset(
        name = unset,
        flag = "//{}:{}".format(native.package_name(), name),
        tags = ["manual"],
    )
    native.label_flag(
        name = name,
        build_setting_default = ":" + unset,
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )
