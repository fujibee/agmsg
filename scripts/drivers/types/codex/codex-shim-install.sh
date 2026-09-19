#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AGENTS_BIN="$HOME/.agents/bin"
TARGET="$AGENTS_BIN/codex"

usage() {
  cat <<EOF
Usage: codex-shim-install.sh [function|install|remove|status]

Prints the recommended shell function for agmsg Codex monitor mode.
With no subcommand, prints the function.

The optional global PATH shim can still be installed at:
  $TARGET

The function and PATH shim both route only interactive Codex launches through
agmsg's monitor bridge when the current project is in Codex monitor mode.
EOF
}

is_agmsg_shim() {
  [ -f "$TARGET" ] && grep -q "Optional Codex entrypoint shim for agmsg monitor mode" "$TARGET" 2>/dev/null
}

shell_quote() {
  printf '%q' "$1"
}

# Lists this machine's agmsg install candidates, one per line: every
# directory under ~/.agents/skills carrying a `.agmsg` marker file. Derives
# the set directly from this machine's actual state -- not from whether
# #599's fail-closed multi-install handling (PR #659) happens to be merged
# on whatever branch calls this, which it may not be (review finding:
# measure the base, don't assume another PR landed).
#
# Kept separate from agmsg_only_one_install below so #659's own bare-
# `--update` candidate enumeration -- not written yet, #659 is still open
# against `main` and unmerged -- has something to consume instead of
# re-scanning ~/.agents/skills a second time, once the two share a base.
# Until #659 lands, this duplicates (rather than shares) that logic; this
# is the known, accepted overlap flagged in review.
agmsg_install_candidates() {
  local skills_dir d
  skills_dir="$(dirname "$AGENTS_BIN")/skills"
  [ -d "$skills_dir" ] || return 0
  for d in "$skills_dir"/*/; do
    [ -f "${d}.agmsg" ] || continue
    printf '%s\n' "${d%/}"
  done
}

# True iff no agmsg install OTHER THAN this one (SCRIPT_DIR) is among
# agmsg_install_candidates.
#
# What this buys: a legacy shim (agmsg's, but predating ownership tracking,
# #553) has no recorded owner to compare against -- but if this is
# PROVABLY the only agmsg install on the machine, nothing else could have
# written it, so claiming it needs no --cmd/--force to be safe. With two or
# more installs present, this returns false and the caller falls back to
# fail-closed, same as an unrecorded owner always has since #553.
#
# Counts "other than me" rather than a plain candidate-count check for
# exactly one, and treats myself as a candidate whether or not my own
# .agmsg marker is on disk yet (review finding): install.sh's fresh --cmd
# path checks/refreshes the shim BEFORE it touches this install's own
# marker, so during a fresh install this install's marker genuinely does
# not exist yet. A plain candidate count would then see only the FIRST
# install's marker, conclude "only one install exists", and let a second,
# distinctly different install silently claim a legacy shim without --force
# -- the very bug this file exists to prevent.
#
# agmsg_install_candidates lists skill-root directories (one level under
# ~/.agents/skills), but SCRIPT_DIR is the nested .../scripts/drivers/types/
# codex directory beneath one -- comparing SCRIPT_DIR itself against those
# entries would never match, so strip the fixed suffix install.sh always
# lays this script out under to recover my own skill root first.
#
# The implicit "I count as a candidate" exception is granted ONLY when that
# recovered self_root actually sits directly under ~/.agents/skills -- i.e.
# SCRIPT_DIR really has the shape install.sh lays this script out under.
# Without that check, running this script directly against some unrelated
# location (as several of this file's own tests do, standing in for "an
# install" without a real ~/.agents/skills tree at all) would trivially
# satisfy "zero others" the moment ~/.agents/skills is empty or absent --
# self can't be trusted as a real, soon-to-register install just because it
# also doesn't show up as an "other". In that fallback case this reverts to
# the plain, pre-self-aware question: is there exactly one REAL marked
# candidate on disk, full stop.
#
# awk (not `grep -v | wc -l`) because it always exits 0, so a count of zero
# others never trips this script's `set -o pipefail` the way a no-match
# grep would.
agmsg_only_one_install() {
  local skills_dir self_root
  skills_dir="$(dirname "$AGENTS_BIN")/skills"
  self_root="${SCRIPT_DIR%/scripts/drivers/types/codex}"
  if [ "$SCRIPT_DIR" != "$self_root" ] && [ "$(dirname "$self_root")" = "$skills_dir" ]; then
    local other_count
    other_count="$(agmsg_install_candidates | awk -v self="$self_root" '$0 != self {c++} END {print c + 0}')"
    [ "$other_count" -eq 0 ]
  else
    local count
    count="$(agmsg_install_candidates | wc -l | tr -d ' ')"
    [ "$count" -eq 1 ]
  fi
}

# Prints the shell-QUOTED (%q) skill script dir baked into the currently-
# installed shim -- empty if there is none, the shim is not an agmsg shim, or
# it predates ownership tracking (#553; see below). This is the install that
# "owns" the shim: the one whose codex-shim.sh it execs into and whose
# storage/drivers every Codex launch through it will resolve.
#
# Reads a DEDICATED comment line (`# agmsg-shim-owner: <%q-quoted dir>`,
# written by `install` below) via plain string extraction -- never eval, and
# never the executable `export AGMSG_CODEX_SHIM_SCRIPT_DIR=...` line the shim
# itself needs at runtime. is_agmsg_shim matching only proves the marker
# STRING is present; it says nothing about the rest of the file's contents,
# which on a local, single-user path like this one could have been hand-
# edited after the fact. Evaling anything sourced from it -- as an earlier
# version of this function did -- turns a read-only `status` call into an
# arbitrary-code-execution path for whoever can write $TARGET (security
# review finding). Plain text extraction has no such path regardless of what
# the line contains.
#
# Quoted, not raw, on this side too (every caller compares/prints this value
# against another %q-quoted value, never an unquoted path) -- a path
# containing a literal newline would otherwise let its OWN content forge a
# second, fake comment line (security review, non-blocking but cheap to
# close). Neither side ever needs the literal path back, only equality and
# display, both of which a consistently-quoted value still gives correctly.
shim_owner_script_dir() {
  is_agmsg_shim || return 0
  sed -n 's/^# agmsg-shim-owner: //p' "$TARGET" 2>/dev/null | head -1
}

cmd="${1:-function}"
case "$cmd" in
  -h|--help)
    usage
    ;;
  function|print-function|shell-function)
    cat <<EOF
# agmsg Codex monitor: put this in your interactive shell profile.
codex() {
  $(shell_quote "$SCRIPT_DIR/codex-shim.sh") "\$@"
}
EOF
    ;;
  install)
    mkdir -p "$AGENTS_BIN"
    if [ -e "$TARGET" ] && ! is_agmsg_shim; then
      echo "codex-shim-install: refusing to overwrite existing $TARGET" >&2
      echo "codex-shim-install: move it aside or remove it first" >&2
      exit 1
    fi
    # The shim path is one file shared by every install on the machine (#553):
    # whichever install's `install` ran last wins, and every Codex launch
    # through the shim then dispatches into ITS drivers/storage — silently,
    # since nothing here previously recorded whose the existing one was.
    #
    # A shim that IS ours (is_agmsg_shim, checked above) but carries no
    # `# agmsg-shim-owner:` line at all is not evidence of "unowned" — it is
    # every shim this tool ever wrote before this check existed. Treating
    # "no owner recorded" as "safe to take" would silently repeat #553's own
    # bug for exactly the migration moment it matters most: the first time a
    # second-named install runs an installer that HAS this fix, against a
    # production shim that does not (review finding). Both a foreign-owned
    # and an owner-unknown shim fail closed here; only a shim already
    # recording THIS install's own SCRIPT_DIR skips the guard.
    self_owner="$(shell_quote "$SCRIPT_DIR")"
    owner="$(shim_owner_script_dir)"
    # An owner-unknown (legacy) shim is claimable WITHOUT --force when this is
    # provably the only agmsg install on the machine: nothing else could have
    # written it, so there is no one to take it from. This is what keeps the
    # ordinary, single-install upgrade path working -- most real machines,
    # migrating from a shim written before ownership tracking existed --
    # without reopening the multi-install theft this whole guard exists to
    # close (review finding: the two fixes above, each correct alone, combined
    # to block the routine case they were never meant to touch).
    legacy_but_sole_install=false
    [ -z "$owner" ] && agmsg_only_one_install && legacy_but_sole_install=true
    if [ -e "$TARGET" ] && [ "$owner" != "$self_owner" ] && [ "${AGMSG_CODEX_SHIM_FORCE:-}" != "1" ] \
        && [ "$legacy_but_sole_install" != true ]; then
      if [ -n "$owner" ]; then
        echo "codex-shim-install: $TARGET is owned by a different install:" >&2
        echo "  $owner" >&2
      else
        echo "codex-shim-install: $TARGET is an agmsg shim from before ownership tracking (#553)," >&2
        echo "codex-shim-install: so which install actually owns it cannot be named." >&2
      fi
      echo "codex-shim-install: refusing to repoint it at $SCRIPT_DIR" >&2
      echo "codex-shim-install: to claim it for THIS install instead, re-run with AGMSG_CODEX_SHIM_FORCE=1 --" >&2
      echo "codex-shim-install: every Codex launch that goes through the shim will then dispatch into $SCRIPT_DIR" >&2
      exit 1
    fi
    {
      echo "#!/usr/bin/env bash"
      echo "set -euo pipefail"
      echo ""
      echo "# Optional Codex entrypoint shim for agmsg monitor mode."
      echo "# Generated by agmsg. Dispatches to the installed skill script."
      # Comment, never executed: the ownership marker shim_owner_script_dir
      # reads with plain text extraction, not eval. %q-quoted (not the raw
      # path) so a path containing a literal newline can't forge a second,
      # fake comment line of its own -- every reader compares/prints this
      # quoted, never unquotes it back to a real path.
      echo "# agmsg-shim-owner: $self_owner"
      echo ""
      echo "export AGMSG_CODEX_SHIM_WRAPPER=1"
      echo "export AGMSG_CODEX_SHIM_SCRIPT_DIR=$(shell_quote "$SCRIPT_DIR")"
      echo "export AGMSG_CODEX_SHIM_TARGET=$(shell_quote "$TARGET")"
      echo "exec $(shell_quote "$SCRIPT_DIR/codex-shim.sh") \"\$@\""
    } > "$TARGET"
    chmod +x "$TARGET"
    if [ "${AGMSG_CODEX_SHIM_INSTALL_QUIET:-}" != "1" ]; then
      echo "installed: $TARGET"
      case ":$PATH:" in
        *":$AGENTS_BIN:"*) ;;
        *)
          echo "note: this optional global shim needs $AGENTS_BIN before the real Codex binary on PATH"
          ;;
      esac
    fi
    ;;
  remove|uninstall)
    if is_agmsg_shim; then
      rm -f "$TARGET"
      echo "removed: $TARGET"
    elif [ -e "$TARGET" ]; then
      echo "codex-shim-install: $TARGET exists but is not the agmsg shim; leaving it untouched" >&2
      exit 1
    else
      echo "not installed: $TARGET"
    fi
    ;;
  status)
    if is_agmsg_shim; then
      echo "installed: $TARGET"
      # A second, separate line, not appended to the first. The "installed:"
      # prefix a caller matches on is unchanged either way, but a caller
      # piping this straight into `grep -q` (rather than capturing it first)
      # can still break under `pipefail` once there is a second line at all —
      # see install.sh's own callers for why, and capture before grep there.
      owner="$(shim_owner_script_dir)"
      if [ "$owner" = "$(shell_quote "$SCRIPT_DIR")" ]; then
        echo "owner: this install ($SCRIPT_DIR)"
      elif [ -n "$owner" ]; then
        echo "owner: a different install ($owner)"
      else
        echo "owner: unknown (predates ownership tracking, #553)"
      fi
    else
      echo "not installed: $TARGET"
    fi
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
