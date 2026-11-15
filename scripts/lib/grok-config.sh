#!/usr/bin/env bash
# grok-build config.toml editing for agmsgd delivery mode's leader socket
# requirement -- the grok-queue channel talks to the TUI's leader over ACP,
# which only exists when the TUI itself was started with [cli] use_leader =
# true (measured live, 2026-11-15; no config key moves the socket path
# itself, only the CLI's own --leader-socket flag does, which agmsg does not
# control here).
#
# Scoped the same way Codex's own sandbox config edit is (lib/codex-config.sh):
# write the key ONLY when it was not already present, remember (in a marker
# file under SKILL_DIR/run, never in the user's own config) that THIS install
# is the one that added it, and on opt-out/uninstall remove the key ONLY when
# that marker says we own it. A value the user set themselves -- true or
# false -- is never touched either way.
#
# use_leader is a plain TOML boolean (never a multi-line value), so unlike
# codex_roots_scan's array editor this needs no string-literal parsing: one
# line is the whole key, scoped to the FIRST matching `[cli]` table header
# (TOML forbids declaring the same table twice, so there is at most one).

# Prints the active grok config path. GROK_HOME mirrors CODEX_HOME's role —
# an explicit override isolates the profile under test; never fall back to
# editing the real profile when it is set (same reasoning as #1718).
agmsg_grok_config_path() {
  printf '%s/config.toml\n' "${GROK_HOME:-$HOME/.grok}"
}

# One marker per distinct config path this install has ever enabled
# use_leader for, so a later `set agmsgd` on a different GROK_HOME (or a
# later opt-out on the same one) never confuses ownership across profiles.
_agmsg_grok_use_leader_marker() {
  local skill_dir="$1" config_path="$2" key
  key="$(printf '%s' "$config_path" | agmsg_sha1)"
  printf '%s/run/grok-config-owns-use-leader.%s\n' "$skill_dir" "$key"
}

# agmsg_grok_use_leader_scan <config.toml>
#
# Reads <config.toml> (nonexistent treated as empty) and reports, on stdout,
# the exact byte value of its FIRST `[cli]` table's `use_leader` key, or
# nothing if the table or key is absent -- same "ok\t<owner>" style
# three-outcome reporting actas_lock_read uses, so a caller cannot mistake
# "not there" for "there but unreadable".
#
# Prints "absent" (no [cli] table, or no use_leader key in it), "true",
# "false", or "other\t<raw>" (some other literal -- never touched, whatever
# it is).
agmsg_grok_use_leader_scan() {
  local path="$1"
  [ -f "$path" ] || { printf 'absent\n'; return 0; }
  awk '
    /^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
      if (seen_cli && !done) { }  # leaving [cli] without a match: still absent
      intbl = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
      if (intbl) seen_cli = 1
      next
    }
    intbl && match($0, /^[ \t]*use_leader[ \t]*=[ \t]*/) {
      v = substr($0, RLENGTH + 1)
      sub(/[ \t\r]*(#.*)?$/, "", v)
      if (v == "true") print "true"
      else if (v == "false") print "false"
      else print "other\t" v
      done = 1
      exit
    }
    END { if (!done) print "absent" }
  ' "$path"
}

# agmsg_grok_use_leader_enable <skill_dir> <config.toml>
#
# Idempotent. If use_leader is already `true` (agmsg's own earlier write, or
# the user's own setting), does nothing and records no new ownership --
# re-running `set agmsgd` twice must not make an opt-out think agmsg owns a
# key the user actually set. If it is `false` or some other literal, leaves
# it untouched (never overwrites an explicit user value) and reports that.
# Only a genuinely ABSENT key is written, and ownership recorded.
#
# Prints one of: already_true, already_set:<value> (user's own, untouched),
# added (agmsg wrote it and now owns it), write_failed.
agmsg_grok_use_leader_enable() {
  local skill_dir="$1" path="$2"
  local current
  current="$(agmsg_grok_use_leader_scan "$path")"
  case "$current" in
    true) printf 'already_true\n'; return 0 ;;
    false) printf 'already_set:false\n'; return 0 ;;
    other*) printf 'already_set:%s\n' "${current#other	}"; return 0 ;;
  esac
  # absent: write it.
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  local tmp created_table
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { printf 'write_failed\n'; return 1; }
  if [ -f "$path" ]; then
    # exit 0 when a [cli] table was already there (found_cli), exit 1 when
    # this write is the one creating it -- read below so the marker can
    # remember whether agmsg owns the table header itself, not only the
    # key (real-machine review, 2026-11-15: an opt-out that only ever
    # removed the key left an orphaned empty `[cli]` heading behind
    # whenever agmsg had created the whole table).
    if awk '
      /^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
        if (incli && !inserted) { print "use_leader = true"; inserted = 1 }
        incli = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
        found_cli = found_cli || incli
        print; next
      }
      { print }
      END {
        if (incli && !inserted) { print "use_leader = true"; inserted = 1 }
        if (!found_cli) { print ""; print "[cli]"; print "use_leader = true" }
        exit !found_cli
      }
    ' "$path" > "$tmp"; then
      created_table=""
    else
      created_table="table"
    fi
  else
    printf '[cli]\nuse_leader = true\n' > "$tmp"
    created_table="table"
  fi
  if ! mv "$tmp" "$path"; then
    rm -f "$tmp"
    printf 'write_failed\n'
    return 1
  fi
  local marker
  marker="$(_agmsg_grok_use_leader_marker "$skill_dir" "$path")"
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  printf '%s' "$created_table" > "$marker" 2>/dev/null || true
  printf 'added\n'
}

# agmsg_grok_use_leader_disable <skill_dir> <config.toml>
#
# Removes the use_leader key ONLY when this install's own marker says it
# added it (see agmsg_grok_use_leader_enable). Any other state -- no
# marker, marker present but the config is now the user's own `false`/other
# value, config missing entirely -- leaves the file untouched. The marker
# itself is always cleaned up here (opt-out is final; re-enabling later adds
# it fresh and re-records ownership).
#
# Prints one of: removed, left_user_owned, nothing_to_do.
agmsg_grok_use_leader_disable() {
  local skill_dir="$1" path="$2"
  local marker owned_table
  marker="$(_agmsg_grok_use_leader_marker "$skill_dir" "$path")"
  if [ ! -f "$marker" ]; then
    printf 'nothing_to_do\n'
    return 0
  fi
  # Read BEFORE removing: "table" means this install's own earlier write
  # also created the [cli] header itself, not only the key (see
  # agmsg_grok_use_leader_enable) -- only that case ever removes the
  # header too, and only when the table is empty besides the key being
  # removed here. A table that already existed (ours from an earlier,
  # different key, or the user's own) is never touched.
  owned_table="$(cat "$marker" 2>/dev/null || true)"
  rm -f "$marker" 2>/dev/null || true
  local current
  current="$(agmsg_grok_use_leader_scan "$path")"
  if [ "$current" != true ]; then
    # The user (or something else) changed it since we added it -- it is
    # theirs now, not agmsg's to remove.
    printf 'left_user_owned\n'
    return 0
  fi
  local tmp1
  tmp1="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { printf 'nothing_to_do\n'; return 0; }
  awk '
    /^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
      incli = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
      print; next
    }
    incli && /^[ \t]*use_leader[ \t]*=[ \t]*true[ \t\r]*(#.*)?$/ { next }
    { print }
  ' "$path" > "$tmp1"
  local final="$tmp1"
  if [ "$owned_table" = table ]; then
    # This install also created the [cli] header itself; drop it too, but
    # ONLY if the table is now otherwise empty (just blank lines until the
    # next header or EOF) -- a table the user added keys to since, or that
    # pre-existed for some other key, is left exactly as it is.
    local tmp2
    tmp2="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { rm -f "$tmp1"; printf 'nothing_to_do\n'; return 0; }
    awk '
      function flush_drop() { pending = ""; buf = "" }
      function flush_keep() { print pending; printf "%s", buf; pending = ""; buf = "" }
      /^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
        if (pending != "") flush_drop()
        if ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/) { pending = $0; buf = ""; next }
        print; next
      }
      {
        if (pending != "") {
          if ($0 ~ /^[ \t]*$/) { buf = buf $0 "\n"; next }
          flush_keep(); print; next
        }
        print
      }
      END { if (pending != "") flush_drop() }
    ' "$tmp1" > "$tmp2"
    rm -f "$tmp1"
    final="$tmp2"
  fi
  if mv "$final" "$path"; then
    printf 'removed\n'
  else
    rm -f "$final"
    printf 'nothing_to_do\n'
  fi
}
