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
  SKD="$BATS_TEST_TMPDIR/skill"
  mkdir -p "$SKD/scripts/drivers/types/claude-code" "$SKD/scripts/drivers/ext-tools/slack" "$SKD/db"
}

# A plugin source checkout at <sha> carrying <axis>/<name>, trusted.
_trusted_source_driver() {  # owner repo sha axis/name
  local d="$SKD/plugins/sources/github/$1/$2/$3/$4"
  mkdir -p "$d"
  printf '%s\t%s\n' "$4" "$d" >> "$SKD/db/trusted-plugins"
}

@test "plugin-shadow: built-in names are listed per axis, sorted, and empty for a first install" {
  run agmsg_builtin_driver_names "$SKD"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'ext-tools/slack\ntypes/claude-code')" ]

  run agmsg_builtin_driver_names "$BATS_TEST_TMPDIR/nothing-here"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plugin-shadow: a new built-in under a trusted source driver's name is named, with remove and untrust" {
  before="$(agmsg_builtin_driver_names "$SKD")"
  _trusted_source_driver acme pack 0123abcd ext-tools/jev
  mkdir -p "$SKD/scripts/drivers/ext-tools/jev"
  run agmsg_plugin_shadow_warn "$SKD" "$before"
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in ext-tools/jev, but your trusted plugin replaces it" <<<"$output"
  grep -Fq -- "$SKD/plugins/sources/github/acme/pack/0123abcd/ext-tools/jev" <<<"$output"
  grep -Fq -- "agmsg plugin remove acme/pack" <<<"$output"
  grep -Fq -- "agmsg plugin untrust ext-tools/jev" <<<"$output"
}

@test "plugin-shadow: a built-in that was already there, an untrusted driver, and a stale trust row stay quiet" {
  # Already a built-in before the update: the install asked about it then.
  _trusted_source_driver acme pack 0123abcd ext-tools/slack
  # A new built-in with a same-named plugin that is NOT trusted: it never runs.
  mkdir -p "$SKD/plugins/sources/github/acme/pack/0123abcd/types/gemini" "$SKD/scripts/drivers/types/gemini"
  # A trust row whose directory is gone.
  printf 'terminals/tmux\t%s\n' "$SKD/plugins/sources/github/acme/old/dead/terminals/tmux" >> "$SKD/db/trusted-plugins"
  mkdir -p "$SKD/scripts/drivers/terminals/tmux"
  before="$(printf 'ext-tools/slack\ntypes/claude-code')"
  run agmsg_plugin_shadow_warn "$SKD" "$before"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "plugin-shadow: a hand-placed trusted plugin gets the untrust hint only; no trust file is quiet" {
  run agmsg_plugin_shadow_warn "$SKD" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  mkdir -p "$SKD/plugins/terminals/orca" "$SKD/scripts/drivers/terminals/orca"
  printf 'terminals/orca\t%s\r\n' "$SKD/plugins/terminals/orca" > "$SKD/db/trusted-plugins"
  run agmsg_plugin_shadow_warn "$SKD" "types/claude-code"
  [ "$status" -eq 0 ]
  grep -Fq -- "adds a built-in terminals/orca" <<<"$output"
  grep -Fq -- "agmsg plugin untrust terminals/orca" <<<"$output"
  run grep -Fq -- "agmsg plugin remove" <<<"$output"
  [ "$status" -ne 0 ]
}

@test "install --update: warns about a trusted plugin that a newly shipped built-in would have been" {
  local fake_home="$BATS_TEST_TMPDIR/home" sk
  sk="$fake_home/.agents/skills/agmsg"
  HOME="$fake_home" bash "$REPO_ROOT/install.sh" --cmd agmsg >/dev/null
  # As if the installed version predates the jev built-in, while a plugin
  # source already provides ext-tools/jev and is trusted.
  rm -rf "$sk/scripts/drivers/ext-tools/jev"
  local d="$sk/plugins/sources/github/acme/pack/0123abcd/ext-tools/jev"
  mkdir -p "$d"
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
