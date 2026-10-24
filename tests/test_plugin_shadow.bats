#!/usr/bin/env bats

# install.sh's warning when an update adds a built-in driver that a trusted
# plugin already replaces (#1594). The lib tests build a fake skill dir; the
# install tests run the real installer into a temp HOME, like test_install.bats.

load test_helper

setup() {
  # install.sh also writes $CODEX_HOME/config.toml when CODEX_HOME is set; a
  # developer shell's real profile must never receive this suite's paths.
  unset CODEX_HOME
  export AGMSG_AGENT_PID=""
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  # shellcheck disable=SC1091
  . "$REPO_ROOT/scripts/lib/plugin-shadow.sh"
  # A skill dir with the real registry libs, so "which driver runs" is the
  # registry's own answer.
  SKD="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$SKD/scripts" "$SKD/db"
  cp -R "$REPO_ROOT/scripts/lib" "$SKD/scripts/lib"
  _driver "$SKD/scripts/drivers" types claude-code
  _driver "$SKD/scripts/drivers" ext-tools slack
  unset AGMSG_PLUGIN_DIRS
}

# <base>/<axis>/<name> with the manifest its registry requires.
_driver() {  # base axis name
  local d="$1/$2/$3"
  mkdir -p "$d"
  case "$2" in
    types) echo 'name=x' > "$d/type.conf" ;;
    terminals) echo 'name=x' > "$d/terminal.conf" ;;
    ext-tools) echo 'timeout=5' > "$d/tool.conf" ;;
  esac
}

_trust() {  # axis/name dir
  printf '%s\t%s\n' "$1" "$2" >> "$SKD/db/trusted-plugins"
}

# A plugin source checkout at <sha>, recorded in db/plugin-sources (so the
# registry searches it), carrying a trusted <axis>/<name>.
_trusted_source_driver() {  # owner repo sha axis name
  local src="$SKD/plugins/sources/github/$1/$2/$3"
  _driver "$src" "$4" "$5"
  printf 'github/%s/%s\t%s/%s\t%s\t%s\t2026-01-01T00:00:00Z\n' "$1" "$2" "$1" "$2" "$3" "$src" >> "$SKD/db/plugin-sources"
  _trust "$4/$5" "$src/$4/$5"
}

@test "plugin-shadow: built-in names are listed per axis, sorted, and empty for a first install" {
  run agmsg_builtin_driver_names "$SKD"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ext-tools/slack\ntypes/claude-code')" ]

  run agmsg_builtin_driver_names "$BATS_TEST_TMPDIR/nothing-here"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plugin-shadow: a first install (no skill dir yet) passes both calls under install.sh's set -euo pipefail" {
  run bash -c 'set -euo pipefail
    . "$1"
    before="$(agmsg_builtin_driver_names "$2")"
    agmsg_plugin_shadow_warn "$2" "$before"
    printf "reached:[%s]\n" "$before"' _ "$REPO_ROOT/scripts/lib/plugin-shadow.sh" "$BATS_TEST_TMPDIR/not-installed-yet"
  [ "$status" -eq 0 ]
  [ "$output" = "reached:[]" ]
}

@test "plugin-shadow: a new built-in that a trusted source driver wins over is named, untrust first" {
  before="$(agmsg_builtin_driver_names "$SKD")"
  _trusted_source_driver acme pack 0123abcd ext-tools jev
  _driver "$SKD/scripts/drivers" ext-tools jev
  run agmsg_plugin_shadow_warn "$SKD" "$before"
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in ext-tools/jev, but your trusted plugin replaces it" <<<"$output"
  grep -Fq -- "$SKD/plugins/sources/github/acme/pack/0123abcd/ext-tools/jev" <<<"$output"
  grep -Fq -- "agmsg plugin untrust ext-tools/jev" <<<"$output"
  grep -Fq -- "remove the whole plugin source (every driver it provides)" <<<"$output"
  grep -Fq -- "agmsg plugin remove acme/pack" <<<"$output"
}

@test "plugin-shadow: quiet whenever the registry still picks the built-in" {
  before="$(agmsg_builtin_driver_names "$SKD")"
  # Already a built-in before the update: the install asked about it then.
  _trusted_source_driver acme pack 0123abcd ext-tools slack
  # New built-in; a same-named plugin that is NOT trusted never runs.
  _driver "$SKD/plugins" types gemini
  _driver "$SKD/scripts/drivers" types gemini
  # New built-in; a trusted copy in a directory that is no search base.
  _driver "$BATS_TEST_TMPDIR/elsewhere" terminals newterm
  _trust terminals/newterm "$BATS_TEST_TMPDIR/elsewhere/terminals/newterm"
  _driver "$SKD/scripts/drivers" terminals newterm
  # New built-in; a trust row with a CR, which the registry's exact match rejects.
  _driver "$SKD/plugins" terminals crterm
  printf 'terminals/crterm\t%s\r\n' "$SKD/plugins/terminals/crterm" >> "$SKD/db/trusted-plugins"
  _driver "$SKD/scripts/drivers" terminals crterm
  # New built-in; a trusted plugin dir with no manifest.
  mkdir -p "$SKD/plugins/ext-tools/nomani"
  _trust ext-tools/nomani "$SKD/plugins/ext-tools/nomani"
  _driver "$SKD/scripts/drivers" ext-tools nomani
  run agmsg_plugin_shadow_warn "$SKD" "$before"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plugin-shadow: a trusted hand-placed or AGMSG_PLUGIN_DIRS plugin gets the untrust hint only; no trust file is quiet" {
  run agmsg_plugin_shadow_warn "$SKD" ""
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in" <<<"$output" && return 1

  before="$(agmsg_builtin_driver_names "$SKD")"
  _driver "$SKD/plugins" terminals orca
  _trust terminals/orca "$SKD/plugins/terminals/orca"
  _driver "$SKD/scripts/drivers" terminals orca
  _driver "$BATS_TEST_TMPDIR/extra" types grok
  _trust types/grok "$BATS_TEST_TMPDIR/extra/types/grok"
  _driver "$SKD/scripts/drivers" types grok
  AGMSG_PLUGIN_DIRS="$BATS_TEST_TMPDIR/extra" run agmsg_plugin_shadow_warn "$SKD" "$before"
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in terminals/orca" <<<"$output"
  grep -Fq -- "agmsg plugin untrust terminals/orca" <<<"$output"
  grep -Fq -- "adds a built-in types/grok" <<<"$output"
  grep -Fq -- "agmsg plugin untrust types/grok" <<<"$output"
  grep -Fq -- "agmsg plugin remove" <<<"$output" && return 1
  return 0
}

@test "install --update: warns about a trusted plugin that a newly shipped built-in would have been" {
  local fake_home="$BATS_TEST_TMPDIR/home" sk
  sk="$fake_home/.agents/skills/agmsg"
  HOME="$fake_home" bash "$REPO_ROOT/install.sh" --cmd agmsg >/dev/null
  # As if the installed version predates the jev built-in, while a plugin
  # source already provides ext-tools/jev and is trusted.
  rm -rf "$sk/scripts/drivers/ext-tools/jev"
  local src="$sk/plugins/sources/github/acme/pack/0123abcd"
  local d="$src/ext-tools/jev"
  _driver "$src" ext-tools jev
  printf 'github/acme/pack\tacme/pack\t0123abcd\t%s\t2026-01-01T00:00:00Z\n' "$src" >> "$sk/db/plugin-sources"
  printf 'ext-tools/jev\t%s\n' "$d" >> "$sk/db/trusted-plugins"

  HOME="$fake_home" run bash "$REPO_ROOT/install.sh" --update
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in ext-tools/jev, but your trusted plugin replaces it" <<<"$output"
  grep -Fq -- "agmsg plugin remove acme/pack" <<<"$output"
  # Warn only: the trust row and the plugin stay.
  grep -qxF "$(printf 'ext-tools/jev\t%s' "$d")" "$sk/db/trusted-plugins"
  [ -d "$d" ]

  # The next update has nothing new to say.
  HOME="$fake_home" run bash "$REPO_ROOT/install.sh" --update
  [ "$status" -eq 0 ]
  run grep -Fq -- "adds a built-in" <<<"$output"
  [ "$status" -ne 0 ]
}
