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

Local steps:

```bash
# 1. Bump VERSION (semver — must NOT include a leading "v").
echo 1.0.1 > VERSION

# 2. Sync derived files.
./scripts/release/sync-version.sh

# 3. Commit and tag.
git add VERSION package.json .claude-plugin/plugin.json
git commit -m "release: 1.0.1"
git tag v1.0.1
git push --follow-tags
```

The tag push fires [`.github/workflows/release.yml`](.github/workflows/release.yml),
which:

1. Verifies the tag matches `VERSION` and that derived files are in sync
   (`sync-version.sh --check`).
2. Waits for a reviewer to approve the `production` environment.
3. Runs `npm publish --access public --provenance`.
4. Creates a GitHub Release.

If the workflow fails on the sync check, you forgot step 2 locally — bump
again, commit, delete and re-push the tag.

## Manual fallback (CI unavailable)

```bash
./scripts/release/sync-version.sh
git add VERSION package.json .claude-plugin/plugin.json && git commit -m "release: $(cat VERSION)"
git tag "v$(cat VERSION)"
git push --follow-tags
npm publish --access public --provenance
gh release create "v$(cat VERSION)" --title "v$(cat VERSION)" --notes "Release $(cat VERSION)."
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
