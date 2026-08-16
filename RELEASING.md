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
Conventional Commits (via [git-cliff](https://git-cliff.org)) **for a stable
version only**, opens a `release: <version>` PR — **and stops there**.

It does **not** enable auto-merge, does not tag, and does not publish. Merging
the PR and pushing the tag are the two outward, irreversible steps, and each
stays behind a person. The script prints the remaining commands when it exits.
(This paragraph used to say it auto-merged and tagged. It never did.)

**Which branch:** whichever one you are on. The PR targets that same branch, so
a prerelease cut from `integration/remote` opens against `integration/remote`.
Releases from a side branch are a real case — 1.2.0-rc.1 through rc.3 were all
cut that way — and the script used to refuse them outright (#679).

**Prereleases skip the changelog.** A version with a prerelease suffix
(`1.2.0-rc.4`) leaves `CHANGELOG.md` untouched; the GitHub Release notes come
from `release.yml`'s own `git-cliff --latest`. Writing the section on an
integration branch would later merge into `main` a section for a version `main`
never had.

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
3. Runs `npm publish --access public --provenance --tag <dist-tag>`, where the
   dist-tag is `next` for a version carrying a prerelease suffix and `latest`
   otherwise. npm reads nothing from the version string on its own — without
   the flag, `1.2.0-rc.4` would land on `latest` exactly like `1.2.0` and every
   `npx agmsg` would get it.
4. Generates the release notes for the tag with git-cliff and creates a
   GitHub Release from them.

### Manual steps (if you'd rather not use the script)

The base is a variable here for the same reason it is one in the script: an rc
is cut from `integration/remote`, and a copy-paste that says `main` puts the
release commit on the wrong branch.

```bash
BASE=main                 # integration/remote for a prerelease
VER=1.0.4                 # 1.2.0-rc.4 for a prerelease

# On an up-to-date $BASE, on a release branch:
git switch "$BASE" && git pull --ff-only origin "$BASE"
git switch -c "release/v$VER"
echo "$VER" > VERSION
./scripts/release/sync-version.sh
FILES="VERSION package.json .claude-plugin/plugin.json"
# A prerelease leaves CHANGELOG.md alone — see "Prereleases skip the changelog"
# above. For a stable version, and only then:
case "$VER" in *-*) ;; *)
  git-cliff --tag "v$VER" -o CHANGELOG.md
  FILES="$FILES CHANGELOG.md" ;;
esac
git add $FILES
git commit -m "release: $VER"
git push -u origin "release/v$VER"
gh pr create --base "$BASE" --fill
```

**Stop there.** Do not add `--auto`: the merge is a gate, not a formality, and
the script does not enable auto-merge for the same reason. Merge it yourself
once the required checks are green, then:

```bash
gh pr merge "release/v$VER" --squash --delete-branch
git switch "$BASE" && git pull --ff-only origin "$BASE"
git tag "v$VER" && git push origin "v$VER"
```

The tag push fires `release.yml`, which waits for the `production` approval
before it publishes.

## If the release run fails

**There is no local publish path, and this section used to print one.** It said
to run `npm publish --access public --provenance` from a workstation. That
cannot work and must not be attempted:

- npm accepts a publish for this package **only** from a GitHub Actions run
  that proves via OIDC it came from this repo, this workflow, and the
  `production` environment. There is no `NPM_TOKEN` anywhere, and the package
  is set to require 2FA and disallow tokens — see "Supply-chain guards" below,
  which the old command contradicted on the same page.
- Even if it could authenticate, it would go around the `production` approval,
  which is the one human gate between a pushed tag and a published package.

So a failed run is re-run, never worked around. **Find out which side of the
publish it failed on first** — a red run does not mean nothing shipped. The
publish step sits in the middle of the job: the release notes and the GitHub
Release are created *after* it, so a failure in either leaves an npm version
that is already public and **immutable**.

```bash
npm view agmsg@1.0.4 version     # prints the version if it published, else errors
```

**Not on npm** — the run failed before publishing (the tag/`VERSION` guard, the
derived-files check, or the approval). Nothing is public. Re-run it, or if the
tag itself was wrong, delete the tag and cut again:

```bash
gh run rerun <run-id> --failed         # approval still applies
git push origin :refs/tags/v1.0.4 && git tag -d v1.0.4
```

**Already on npm** — the version is permanent; npm does not allow a re-publish
of the same version, and deleting the tag would only detach the release from
its source. Do not delete it. Finish the rest:

```bash
gh run rerun <run-id> --failed
```

That is safe to repeat: the publish step checks `npm view` first and skips when
the version is already there, so a re-run picks up at the release notes.

If GitHub Actions is unavailable, the release waits. A release that cannot go
through the pipeline is a release that has not been reviewed, signed, or
attested, and shipping it by hand would remove every guarantee the pipeline
exists to make.

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
  PR to `main` **and `integration/remote`**. A hand-edit of `package.json` or
  `plugin.json` without a `VERSION` bump fails CI before merge. It was
  `main`-only until #679, which meant it never ran on any of the three
  prereleases cut from `integration/remote` — `release.yml` runs the same check
  at tag time, so nothing shipped out of sync, but the failure would have
  surfaced at publish rather than at review.

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
