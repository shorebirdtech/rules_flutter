# Maintenance Chores

Central reference for all recurring maintenance tasks. Slash commands read this
file at runtime — keep file lists current as the repo evolves.

---

## Flutter Version Bump

**Trigger**: New Flutter stable release.

**Authoritative source**: The Flutter reference repo tags are the source of truth for the
latest stable version. Do NOT rely on web searches — they may be stale. Run:

```sh
git -C ../flutter fetch --tags
git -C ../flutter tag -l '[0-9]*' | grep -v pre | sort -V | tail -5
```

The latest tag is the current stable release.

**Files**:

- `flutter/private/versions.bzl` — `FLUTTER_VERSIONS` and `ARTIFACT_CHECKSUMS` dicts
- `MODULE.bazel` — `flutter_version` in `flutter.toolchain()` call
- All `e2e/*/MODULE.bazel` — `flutter_version` in `flutter.toolchain()` calls
- `e2e/_overlay_tests/*/MODULE.bazel` — same call, one directory deeper, so a
  `e2e/*/MODULE.bazel` glob misses it
- `README.md` — the Flutter version in the Requirements table, the
  `MODULE.bazel` snippet under Getting started, and the `FlutterSdkInfo.version`
  example under Providers

**Procedure**:

1. Fetch tags and identify the latest stable version (see above)
2. Run `bazel run //tools/update_flutter_version -- <new-version>` (requires Flutter reference
   repo beside this one at `../flutter`, or `FLUTTER_REPO`, with tags fetched)
3. Copy the printed snippets into `flutter/private/versions.bzl`
4. Update `flutter_version` in `MODULE.bazel` and all `e2e/*/MODULE.bazel` files
5. Regenerate lock files

**Verification**: `bazel test //flutter/tests:all` and `cd e2e/smoke && bazel test //...`

---

## Bazel Version Bump

**Trigger**: New Bazel release (typically minor/patch within 9.x).

**Files**:

- Every `.bazelversion` — the repo root plus one per workspace with a
  `MODULE.bazel`, including `e2e/_overlay_tests/*`. A workspace without one does
  not inherit the root's: bazelisk reads only its own workspace root and
  otherwise fetches the newest release, so a missing file silently runs a
  different Bazel than the rest of the sweep.
  `find . -name .bazelversion -not -path '*/bazel-*'` is the list.
- `.bcr/presubmit.yml` — `bazel:` matrix value (if major version changes)

**Procedure**:

1. Update all `.bazelversion` files to the new version
2. If the major version changed, update `.bcr/presubmit.yml` matrix
3. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-bazel {version}` slash command.

---

## Bazel Module Dependency Bumps

**Trigger**: Periodic (monthly) or when a dep releases a version we need.

**Files**:

- `MODULE.bazel` — `bazel_dep()` version strings
- Every `e2e/*/MODULE.bazel` and `e2e/_overlay_tests/*/MODULE.bazel` — these
  declare their own `bazel_dep`s rather than inheriting the root's, so a root-only
  bump leaves them behind. `bazel_skylib`, `rules_cc` and `apple_support` appear
  in most; `rules_android`, `rules_kotlin`, `rules_java`, `rules_jvm_external`
  and `rules_go` in the three Android ones; `llvm` only in
  `cross_compile_example`

**Procedure**:

1. For each `bazel_dep` in root `MODULE.bazel`, check latest version on BCR
2. Update versions, skip any already current
3. Mirror the same versions into the e2e workspaces that declare them
4. Regenerate lock files

**Verification**: `bazel build //...` passes.

**Automation**: `/bump-deps` slash command.

---

## Lock File Refresh

**Trigger**: After any change to the root `MODULE.bazel`, its transitive deps,
or `.bazelversion` — the lock records a format version (Bazel 9.1.0 writes 26,
9.2.0 writes 28) as well as registry hashes.

**Only the root lock is enforced.** Every `e2e/*` workspace sets
`--lockfile_mode=off` in its own `.bazelrc`, because each one is overridden onto
a sibling `rules_dart` in local development, and their locks are intentionally
left stale. Refreshing them produces a large diff that nothing checks.

**Procedure**: move `.bazelrc.user` aside — its `--override_module` line changes
the module graph away from the registry one CI resolves, and forces
`--lockfile_mode` off — then `bazel mod deps --lockfile_mode=update`, then put it
back. Any host will do.

**Verification**: to check the lock the way CI does, move `.bazelrc.user`
aside and run `bazel mod deps --lockfile_mode=error`.

**Automation**: none.

---

## Release Archive Contents

**Trigger**: Adding or removing an e2e workspace, or any top-level directory.

**Files**: `.gitattributes`

The release archive is `git archive` output, so `export-ignore` decides what a
consumer downloads — and what BCR presubmit runs against. Extracting an archive
and building it is the only thing that catches either of these:

- **Patterns must be anchored with a leading `/`.** Without one they match a
  basename at any depth: `e2e/` also stripped `tools/dev_tool/test/e2e/`, and
  that package's `glob(["test/e2e/**/*.dart"])` then failed the whole archive at
  load time with "glob pattern didn't match anything, but allow_empty is set to
  False". The archive did not build at all, and nothing in CI looks at it.
- **`e2e/smoke` has to stay in.** `.bcr/presubmit.yml` names it as
  `module_path`, and BCR resolves that inside the extracted archive. It was
  excluded along with the rest of `e2e/`.

So `/e2e/` is excluded workspace by workspace rather than wholesale. **A new e2e
workspace needs a line here**, or it ships in the archive: the whole tree is 12MB
against a 1.5MB archive.

**Verification**: `git archive --format=tar HEAD | tar t` and check that
`e2e/smoke/` and `tools/dev_tool/test/e2e/` are present and no other e2e
workspace is. To check it builds, extract the archive somewhere clean and run
`bazel build --nobuild //...` — the load phase is what these mistakes break.

---

## BCR Presubmit Config

**Trigger**: When changing the test module or Bazel version requirements.

**Files**:

- `.bcr/presubmit.yml` — module_path, platform matrix, bazel matrix

**Procedure**: Update the YAML to match current requirements.

**Verification**: BCR presubmit passes after publishing.

**Automation**: Manual — changes are rare and coupled to other chores.

---

## Documentation Accuracy

**Trigger**: After any structural change (new rules, new e2e workspaces, etc.).

**Files**:

- `README.md` — examples table, installation snippet, version references. It is
  the architecture document too: `docs/ARCHITECTURE.md` was listed here long
  after it stopped existing, so check what a path names before trusting it
- `docs/TESTING.md` — the e2e workspace list, the sweep commands, the per-device
  tables
- `.github/workflows/ci.yaml` — the prose comments carry version claims of
  their own

**Procedure**: Review hardcoded counts, tables, and version strings against actual state.

**Verification**: Visual inspection.

---

## Tool Version Bumps

**Trigger**: Periodic (monthly) or when a managed tool releases a version we need.

**Files**: none in this repository. `git-cliff`, `prek`, `typos` and `yamlfmt`
are pinned in rules_dart's `overhead/multitool.lock.json`, which every
repository that takes overhead as a dev dependency shares. Bump them there
(rules_dart's CHORES.md has the procedure), then bump the `commit` of the
`overhead` `git_override` in `MODULE.bazel` and the `uses:` refs in
`.github/workflows` to the new rules_dart commit; `bazel run @overhead//pins:check`
fails if they differ.

**Verification**: `bazel run @overhead//lint:prek -- run --all-files --hook-stage manual` passes.

---

## Git Hook Bumps

**Trigger**: New versions of the git hooks (buildifier, etc.).

**Files**:

- `.pre-commit-config.yaml`

**Procedure**: `renovate.json` extends `:enablePreCommit`, but treat this as
manual until you have actually seen a Renovate PR land here.

Reconcile the revs that track something else in this repo:

- `keith/pre-commit-buildifier` is the only buildifier in this repository; pick
  the newest tag of the mirror. The fourth component is the mirror's own
  packaging revision and it tags only some of them (there is no 8.5.1.4).
- The yamlfmt and typos hooks are local hooks that run overhead's pinned
  versions (see § "Tool Version Bumps").
- `pre-commit/mirrors-prettier` is archived upstream; `v3.1.0` is the last
  stable tag and is expected to stay pinned.

**Verification**: `prek run --all-files` passes.

**Automation**: Manual, per above.

---

## GitHub Workflow Dependency Bumps

**Trigger**: Periodic or when a dependency releases a version we need.

**Files**: All `.github/workflows/*.yaml` files.

**Procedure**:

Every `uses:` that is not local (`./.github/...`) is pinned to a full commit SHA
with the version in a trailing comment: `uses: owner/repo@<sha> # v1.2.3`
(`owner/repo/path@<sha> # v1.2.3` for a subpath). A bump changes both.

1. For each `uses:` reference, check the repo's tags/releases for newer versions
2. Resolve the new tag to its commit. For an annotated tag, take the peeled
   `^{}` line (the commit), not the tag object:
   `git ls-remote https://github.com/owner/repo refs/tags/<tag> 'refs/tags/<tag>^{}'`
3. Replace the SHA and the comment together
4. For reusable workflows, review changelogs for new inputs or breaking changes

overhead's workflows (`aran/rules_dart/.github/workflows/overhead-*`) move with
the rules_dart commit instead (see § "Tool Version Bumps").

**Verification**: `bazel test //tools/ci_matrix:pinned_actions_test` passes (it
fails on a `uses:` that is not a 40-hex SHA with a `# <ref>` comment), and the CI
workflow runs successfully.
