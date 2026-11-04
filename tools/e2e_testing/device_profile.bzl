"""The per-developer files a device build of an e2e example is signed with."""

def _unset_impl(ctx):
    fail(
        "\n\nThis target is signed for a physical device and needs your own " +
        "{what}, which this repository does not carry.\n\n".format(what = ctx.attr.what) +
        "Set it up once:\n" +
        "  1. cp -r device.example device\n" +
        "  2. mv device/BUILD.bazel.example device/BUILD.bazel, then edit it " +
        "(device/BUILD.bazel explains how)\n" +
        "  3. echo 'common --{flag}=//device:{target}' >> .bazelrc.user\n\n".format(
            flag = ctx.attr.flag,
            target = ctx.attr.device_target,
        ),
    )

_device_file_unset = rule(
    implementation = _unset_impl,
    attrs = {
        "device_target": attr.string(mandatory = True),
        "flag": attr.string(mandatory = True),
        "what": attr.string(mandatory = True),
    },
    doc = "Fails analysis, saying how to set up a per-developer device file.",
)

def device_flag(name, device_target, what):
    """Declares the label flag a device build takes a per-developer file from.

    The flag's default fails analysis with the setup steps. A checked-in
    `"//device:<target>"` would instead name a package that a fresh clone lacks
    (it is git-ignored and per developer), and `bazel query 'deps(//...)'`
    follows even a `manual` target's labels into it. A developer points the
    flag at the real target in `.bazelrc.user`.

    Args:
        name: The flag's name.
        device_target: The target in `//device` the flag is set to.
        what: What the file is, for the setup message.
    """
    unset = name + "_unset"
    _device_file_unset(
        name = unset,
        device_target = device_target,
        flag = "//{}:{}".format(native.package_name(), name),
        tags = ["manual"],
        what = what,
    )
    native.label_flag(
        name = name,
        build_setting_default = ":" + unset,
        tags = ["manual"],
        visibility = ["//visibility:public"],
    )

def device_profile(name = "device_profile"):
    """Declares the flag a device build takes its provisioning profile from.

    Args:
        name: The flag's name.
    """
    device_flag(name, "profile", "provisioning profile")
