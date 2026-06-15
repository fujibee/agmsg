# Releasing agmsg

agmsg's version lives in one place: the [`VERSION`](VERSION) file at the
repo root. The two files that also carry the version string — `package.json`
(npm) and `.claude-plugin/plugin.json` (Claude Code plugin marketplace) — are
derived from it via [`scripts/release/sync-version.sh`](scripts/release/sync-version.sh).

The npm package `agmsg` is published directly from this repo via npm's
Trusted Publisher (OIDC) binding — there is no `NPM_TOKEN` to leak.
(Earlier releases came from a separate `fujibee/agmsg-npm` bootstrapper
repo; that repo is now archived — see "History" below.)

## Cutting a release

One command does everything:

```bash
scripts/release/cut-release.sh 1.0.4   # semver, no leading "v"
```

It bumps `VERSION`, syncs the derived files, regenerates `CHANGELOG.md` from
Conventional Commits (via [git-cliff](https://git-cliff.org)), opens a
`release: <version>` PR, auto-merges it once the required checks pass, then tags
the merged commit and pushes the tag.

**Why a PR and not a direct push:** `main` is a protected branch with required
status checks, so the release commit must land through a PR — a direct push is
rejected. Tags aren't protected, so the tag push is direct.

**Prerequisite:** install git-cliff once — `brew install git-cliff` (or
`cargo install git-cliff`, or grab a binary from the
[releases](https://github.com/orhun/git-cliff/releases)). The changelog format
is configured in [`cliff.toml`](cliff.toml).

The tag push fires [`.github/workflows/release.yml`](.github/workflows/release.yml),
which:

1. Verifies the tag matches `VERSION` and that derived files are in sync
   (`sync-version.sh --check`).
2. Waits for a reviewer to approve the `production` environment.
3. Runs `npm publish --access public --provenance`.
4. Generates the release notes for the tag with git-cliff and creates a
   GitHub Release from them.

### Manual steps (if you'd rather not use the script)

```bash
# On an up-to-date main, on a release branch:
git switch -c release/v1.0.4
echo 1.0.4 > VERSION
./scripts/release/sync-version.sh
git-cliff --tag v1.0.4 -o CHANGELOG.md
git add VERSION package.json .claude-plugin/plugin.json CHANGELOG.md
git commit -m "release: 1.0.4"
git push -u origin release/v1.0.4
gh pr create --fill && gh pr merge --squash --auto --delete-branch
# After it merges:
git switch main && git pull --ff-only
git tag v1.0.4 && git push origin v1.0.4
```

## Manual fallback (CI unavailable)

```bash
# (after the release commit is on main via PR)
npm publish --access public --provenance
git-cliff --latest --strip header -o RELEASE_NOTES.md
gh release create "v$(cat VERSION)" --title "v$(cat VERSION)" --notes-file RELEASE_NOTES.md
```

## Supply-chain guards

The pipeline layers four defenses against silent drift and malicious publish:

- **npm Trusted Publisher (OIDC).** npmjs.com only accepts a publish from a
  GitHub Actions run that proves (via OIDC) it was triggered from this repo,
  this workflow file, and the `production` environment. There is no long-lived
  `NPM_TOKEN` to steal. Package settings on npmjs.com are also set to
  *require 2FA and disallow tokens*, so the only publish path is this workflow.
- **`production` environment with required reviewer.** A pushed tag pauses at
  the publish step until a maintainer approves the deployment. A compromised
  tag-push alone cannot ship to npm.
- **`--provenance` attestation.** Every published tarball is signed by GitHub
  and linked back to this workflow run. A tarball without provenance — or with
  provenance pointing elsewhere — is distinguishable on npmjs.com.
- **`verify-versions.yml`.** Runs `sync-version.sh --check` on every push and
  PR to `main`. A hand-edit of `package.json` or `plugin.json` without a
  `VERSION` bump fails CI before merge.

## Repository secrets required by the workflow

None — auth to npm is via OIDC.

The Trusted Publisher binding on npmjs.com keys off three things that all
must match:

| Field | Value |
| --- | --- |
| Repository | `fujibee/agmsg` |
| Workflow filename | `release.yml` |
| Environment | `production` |

If any of these is renamed, update the npm Trusted Publisher settings in
lockstep.

## Version constraints

`VERSION` must be semver (`MAJOR.MINOR.PATCH[-prerelease]`). `sync-version.sh`
rejects anything else, including a leading `v`. The tag is always
`v$(cat VERSION)`.

## History

The npm `agmsg` package was originally published from a separate repo,
[`fujibee/agmsg-npm`](https://github.com/fujibee/agmsg-npm), during the
name-registration sprint (issue #80). That repo only contained a thin
JavaScript bootstrapper that downloaded and ran `setup.sh` from this repo.
Keeping it separate added a cross-repo sync surface and bought nothing,
so it was folded back here. The bootstrapper now lives at [`bin/agmsg.js`](bin/agmsg.js).
