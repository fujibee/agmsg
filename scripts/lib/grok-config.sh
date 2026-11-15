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
# line is the whole key, scoped to the FIRST matching bare `[cli]` table
# header (TOML forbids declaring the same table twice, so there is at most
# one of those). TOML allows the SAME key/table to be spelled several other
# ways this does not attempt to parse -- a quoted table header (["cli"]), a
# quoted key ("use_leader" = ...), a dotted key (cli.use_leader = ...), or
# an inline table (cli = { use_leader = ... }). the review on #1979: the
# original scan read every one of those as "absent", so enabling would add
# a SECOND, conflicting use_leader next to the user's real one. Detected
# explicitly below and refused with a reason, never silently misread.

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

# Read-only. True (rc 0) if <config.toml> contains a bare `[cli]` table
# header. Deliberately a SEPARATE, non-mutating check from the awk scripts
# below that insert/remove text -- conflating "the table already existed"
# with "the write succeeded" was the review's finding (4) against the previous
# version (an I/O failure inside the mutating awk could be misread as "no
# table existed yet").
_agmsg_grok_cli_header_present() {
  local path="$1"
  [ -f "$path" ] || return 1
  grep -Eq '^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$' "$path" 2>/dev/null
}

# agmsg_grok_use_leader_scan <config.toml>
#
# Reads <config.toml> (nonexistent treated as empty) and reports, on stdout,
# the exact byte value of its FIRST bare `[cli]` table's bare `use_leader`
# key, or nothing if the table or key is absent -- same "ok\t<owner>" style
# three-outcome reporting actas_lock_read uses, so a caller cannot mistake
# "not there" for "there but unreadable".
#
# Prints "absent" (no [cli] table, or no use_leader key in it), "true",
# "false", "other\t<raw>" (some other literal -- never touched, whatever it
# is), or "unsupported\t<reason>" for a TOML shape this does not attempt to
# parse (see the file header): dotted_key, inline_table, quoted_table_header,
# quoted_key. A caller sees "unsupported" and refuses to write, rather than
# risk a second, conflicting use_leader next to one already there under a
# spelling this does not recognize.
agmsg_grok_use_leader_scan() {
  local path="$1"
  [ -f "$path" ] || { printf 'absent\n'; return 0; }
  local awk_script
  awk_script="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-scan-awk.XXXXXX")" || { printf 'absent\n'; return 0; }
  cat > "$awk_script" <<'AWK_EOF'
/^[ \t]*["']?cli["']?[ \t]*\.[ \t]*["']?use_leader["']?[ \t]*=/ {
  print "unsupported\tdotted_key"; done = 1; exit
}
/^[ \t]*["']?cli["']?[ \t]*=[ \t]*\{/ {
  print "unsupported\tinline_table"; done = 1; exit
}
/^[ \t]*\[[ \t]*["'][ \t]*cli[ \t]*["'][ \t]*\][ \t\r]*(#.*)?$/ {
  print "unsupported\tquoted_table_header"; done = 1; exit
}
/^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
  incli = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
  next
}
incli && /^[ \t]*["']use_leader["'][ \t]*=/ {
  print "unsupported\tquoted_key"; done = 1; exit
}
incli && match($0, /^[ \t]*use_leader[ \t]*=[ \t]*/) {
  v = substr($0, RLENGTH + 1)
  sub(/[ \t\r]*(#.*)?$/, "", v)
  if (v == "true") print "true"
  else if (v == "false") print "false"
  else print "other\t" v
  done = 1
  exit
}
END { if (!done) print "absent" }
AWK_EOF
  awk -f "$awk_script" "$path" 2>/dev/null
  rm -f "$awk_script"
}

# agmsg_grok_use_leader_enable <skill_dir> <config.toml>
#
# Idempotent. If use_leader is already `true` (agmsg's own earlier write, or
# the user's own setting), does nothing and records no new ownership --
# re-running `set agmsgd` twice must not make an opt-out think agmsg owns a
# key the user actually set. If it is `false` or some other literal, or the
# scan reports an unsupported TOML shape, leaves the file untouched entirely
# and reports that. Only a genuinely ABSENT key is written, and ownership
# recorded.
#
# Prints one of: already_true, already_set:<value> (user's own, untouched),
# unsupported:<reason> (a TOML shape not parsed -- see the file header,
# nothing written), added (agmsg wrote it and now owns it), write_failed
# (nothing written; original config and any existing marker untouched).
agmsg_grok_use_leader_enable() {
  local skill_dir="$1" path="$2"
  local current
  current="$(agmsg_grok_use_leader_scan "$path")"
  case "$current" in
    true) printf 'already_true\n'; return 0 ;;
    false) printf 'already_set:false\n'; return 0 ;;
    unsupported*)
      printf 'unsupported:%s\n' "${current#unsupported	}"
      return 1
      ;;
    other*) printf 'already_set:%s\n' "${current#other	}"; return 0 ;;
  esac
  # absent: write it. created_table is decided by a plain, read-only grep
  # (above), never by the mutating awk's own exit status -- an I/O failure
  # inside that awk must never be misread as "no table existed yet" (the review
  # review, finding 4).
  local created_table=""
  _agmsg_grok_cli_header_present "$path" || created_table="table"
  mkdir -p "$(dirname "$path")" 2>/dev/null || true
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { printf 'write_failed\n'; return 1; }
  if [ -f "$path" ]; then
    local awk_script
    awk_script="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-enable-awk.XXXXXX")" || { rm -f "$tmp"; printf 'write_failed\n'; return 1; }
    cat > "$awk_script" <<'AWK_EOF'
/^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
  if (incli && !inserted) { print "use_leader = true"; inserted = 1 }
  incli = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
  print; next
}
{ print }
END {
  if (incli && !inserted) { print "use_leader = true"; inserted = 1 }
  if (!incli && !inserted) {
    # Reached EOF never having been inside [cli] at all: no table existed.
    print ""; print "[cli]"; print "use_leader = true"
  }
}
AWK_EOF
    if ! awk -f "$awk_script" "$path" > "$tmp" 2>/dev/null; then
      rm -f "$awk_script" "$tmp"
      printf 'write_failed\n'
      return 1
    fi
    rm -f "$awk_script"
    # Sanity: a non-empty source must never produce an empty result -- a
    # read/write fault partway through awk can still exit 0 having written
    # nothing. Never mv a suspiciously-emptied file over the real config.
    if [ -s "$path" ] && [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      printf 'write_failed\n'
      return 1
    fi
  else
    printf '[cli]\nuse_leader = true\n' > "$tmp"
  fi
  # Marker committed BEFORE the config change, not after: if writing the
  # marker fails, the config is never touched at all and the whole
  # operation is cleanly retryable (the review, finding 4 -- the previous
  # order could leave use_leader written with no ownership record at all
  # if the marker write failed silently afterward).
  local marker
  marker="$(_agmsg_grok_use_leader_marker "$skill_dir" "$path")"
  mkdir -p "$(dirname "$marker")" 2>/dev/null || true
  local marker_tmp
  marker_tmp="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-marker.XXXXXX")" || { rm -f "$tmp"; printf 'write_failed\n'; return 1; }
  printf '%s' "$created_table" > "$marker_tmp"
  if ! mv "$marker_tmp" "$marker"; then
    rm -f "$marker_tmp" "$tmp"
    printf 'write_failed\n'
    return 1
  fi
  if ! mv "$tmp" "$path"; then
    rm -f "$tmp"
    # The marker now claims ownership of a key that was never actually
    # written. Roll it back rather than leave a false claim behind --
    # the next enable() call (this one, retried, or a future one) will
    # see use_leader genuinely absent and go through this same path again.
    rm -f "$marker" 2>/dev/null || true
    printf 'write_failed\n'
    return 1
  fi
  printf 'added\n'
}

# agmsg_grok_use_leader_disable <skill_dir> <config.toml>
#
# Removes the use_leader key ONLY when this install's own marker says it
# added it (see agmsg_grok_use_leader_enable). Any other state -- no
# marker, marker present but the config is now the user's own `false`/other
# value, config missing entirely -- leaves the file untouched. The marker
# itself is removed only AFTER the config edit actually succeeds (the review
# review, finding 4: removing it first and then hitting a write failure
# used to permanently lose the ownership record for a key that was, in
# fact, never removed).
#
# Prints one of: removed, left_user_owned, unsupported:<reason> (a TOML
# shape not parsed -- see the file header, marker preserved, nothing
# written), write_failed (marker preserved, retryable), nothing_to_do (no
# marker at all).
agmsg_grok_use_leader_disable() {
  local skill_dir="$1" path="$2"
  local marker owned_table
  marker="$(_agmsg_grok_use_leader_marker "$skill_dir" "$path")"
  if [ ! -f "$marker" ]; then
    printf 'nothing_to_do\n'
    return 0
  fi
  owned_table="$(cat "$marker" 2>/dev/null || true)"
  local current
  current="$(agmsg_grok_use_leader_scan "$path")"
  case "$current" in
    unsupported*)
      printf 'unsupported:%s\n' "${current#unsupported	}"
      return 1
      ;;
  esac
  if [ "$current" != true ]; then
    # The user (or something else) changed it since we added it -- it is
    # theirs now, not agmsg's to remove. Nothing of ours is left in the
    # config, so the marker is safe to drop here.
    rm -f "$marker" 2>/dev/null || true
    printf 'left_user_owned\n'
    return 0
  fi
  local tmp1
  tmp1="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { printf 'write_failed\n'; return 1; }
  local awk_script1
  awk_script1="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-disable1-awk.XXXXXX")" || { rm -f "$tmp1"; printf 'write_failed\n'; return 1; }
  cat > "$awk_script1" <<'AWK_EOF'
/^[ \t]*\[[^]]*\][ \t\r]*(#.*)?$/ {
  incli = ($0 ~ /^[ \t]*\[[ \t]*cli[ \t]*\][ \t\r]*(#.*)?$/)
  print; next
}
incli && /^[ \t]*use_leader[ \t]*=[ \t]*true[ \t\r]*(#.*)?$/ { next }
{ print }
AWK_EOF
  if ! awk -f "$awk_script1" "$path" > "$tmp1" 2>/dev/null; then
    rm -f "$awk_script1" "$tmp1"
    printf 'write_failed\n'
    return 1
  fi
  rm -f "$awk_script1"
  if [ -s "$path" ] && [ ! -s "$tmp1" ]; then
    rm -f "$tmp1"
    printf 'write_failed\n'
    return 1
  fi
  local final="$tmp1"
  if [ "$owned_table" = table ]; then
    # This install also created the [cli] header itself; drop it too, but
    # ONLY if the table is now otherwise empty (just blank lines until the
    # next header or EOF) -- a table the user added keys to since, or that
    # pre-existed for some other key, is left exactly as it is.
    local tmp2 awk_script2
    tmp2="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-config.XXXXXX")" || { rm -f "$tmp1"; printf 'write_failed\n'; return 1; }
    awk_script2="$(mktemp "${TMPDIR:-/tmp}/agmsg-grok-disable2-awk.XXXXXX")" || { rm -f "$tmp1" "$tmp2"; printf 'write_failed\n'; return 1; }
    cat > "$awk_script2" <<'AWK_EOF'
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
AWK_EOF
    if ! awk -f "$awk_script2" "$tmp1" > "$tmp2" 2>/dev/null; then
      rm -f "$awk_script2" "$tmp1" "$tmp2"
      printf 'write_failed\n'
      return 1
    fi
    rm -f "$awk_script2" "$tmp1"
    final="$tmp2"
  fi
  if mv "$final" "$path"; then
    rm -f "$marker" 2>/dev/null || true
    printf 'removed\n'
  else
    rm -f "$final"
    printf 'write_failed\n'
    return 1
  fi
}
