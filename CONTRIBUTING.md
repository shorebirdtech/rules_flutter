# How to Contribute

## Formatting

Starlark files must be formatted by buildifier, and YAML files by yamlfmt.
Git hooks check this, along with prettier, typos, file hygiene and the commit
message policy. They run with [prek](https://github.com/j178/prek), which reads
`.pre-commit-config.yaml`. Install prek with [uv](https://docs.astral.sh/uv/)
and set up the hooks once per clone:

```shell
uv tool install prek
prek install -f
```

`-f` replaces hooks already in the clone, such as ones pre-commit installed;
without it prek keeps them and runs them too. The installed hook calls the prek
at `~/.local/bin/prek`, which stays put across `uv tool upgrade prek` and
`bazel clean`. Set `PREK_QUIET=1` in your shell profile for hooks that print
nothing unless one fails.

The commit message, buildifier, yamlfmt, typos and actionlint hooks run
overhead's tools from `.bazel_env/bin`, without Bazel. Set that up in the main checkout, and again
after any `bazel clean` or bump of overhead's pin:

```shell
bazel run @overhead//:bazel_env
```

A hook that fails with "No such file or directory" means it is not set up.

A worktree made with `git worktree add` runs the command above in the
worktree.

CI builds `.bazel_env` and runs the hooks from it. To run every check through
`bazel run` instead, without `.bazel_env`:

```shell
bazel run --enable_runfiles @overhead//lint:prek -- run --all-files --hook-stage manual
```

On Windows, where bazel_env does not run, install the hooks without the ones
that need it and run that command before you push:

```shell
prek install -f --skip commit-message --skip buildifier --skip buildifier-lint --skip yamlfmt --skip typos --skip actionlint
```

## Commit messages

Subjects follow [Conventional Commits](https://www.conventionalcommits.org/),
and user-visible commits carry a `Changelog:` trailer; see
[AGENTS.md](AGENTS.md#changelog). `prek install` sets up the check as the
`commit-msg` hook. To check a message by hand:

```shell
bazel run @overhead//changelog:check -- <message-file>
```

`bazel run @overhead//changelog` prints the release notes the unreleased commits
would produce.

## Using this as a development dependency of other rules

You'll commonly find that you develop in another repository that
depends on rules_flutter.

To always tell Bazel to use this local checkout rather than a release
artifact or a version fetched from the registry, run this from this
directory:

```sh
OVERRIDE="--override_module=rules_flutter=$(pwd)"
echo "common $OVERRIDE" >> ~/.bazelrc
```

This means that any usage of `@rules_flutter` on your system will point to this folder.

## Releasing

This fork does not tag releases or publish to the Bazel Central Registry;
upstream, [aran/rules_flutter](https://github.com/aran/rules_flutter), does.
Consumers of the fork depend on one of its commits (`git_override` or
`archive_override`), and changes from upstream arrive by merge commit.
