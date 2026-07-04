#!/usr/bin/env bash
# hooks-json.sh — JSON/SQLite primitives for editing an agent's settings hooks file.
#
# These are the low-level read-modify-write helpers that delivery.sh uses to add
# and remove agmsg-owned hook entries from a settings.json-shaped file. They are
# pure JSON manipulation built on sqlite3's json1 + readfile()/writefile(), with
# no knowledge of delivery modes or agent-type dispatch (that lives in
# delivery.sh). Split out of delivery.sh so the gnarly sqlite/JSON layer — and
# its accumulated bug-fix guards (#95 E2BIG, #143/#102 control-byte escaping,
# #162 byte-count validation, #134 JSON escaping) — can be read and tested on
# its own.
#
# Sourced by delivery.sh AFTER it defines SKILL_NAME (used to detect
# agmsg-owned entries); the existing lib convention is for sourced modules to
# reference caller-set globals rather than re-resolve them.

sql_readfile_path() {
  local path="$1"
  if command -v cygpath >/dev/null 2>&1; then
    path=$(cygpath -w "$path" 2>/dev/null || printf '%s' "$path")
  fi
  printf '%s' "$path" | sed "s/'/''/g"
}

# Strip any agmsg-owned hook entries from <event> in the JSON at <path>. An
# entry is "agmsg-owned" when one of its inner hooks references a path under
# our skill directory. Result is written back to <path> atomically.
#
# Reads the settings via sqlite3's readfile() rather than interpolating the
# file's contents into the SQL string. The old in-memory chain embedded the
# settings blob 6× into a single sqlite3 argv element; on Linux that hits
# the per-arg MAX_ARG_STRLEN cap (131072 bytes) once the settings file
# crosses ~21 KB, so `delivery.sh set` failed with E2BIG (see #95). Using
# readfile() keeps the file off the argv entirely.
strip_agmsg_event_file() {
  local path="$1"
  local event="$2"
  local sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # Write the result with writefile() rather than redirecting sqlite3's CLI
  # output. On strict sqlite3 builds (>= 3.50, shipped on Windows) the CLI
  # renders control bytes — e.g. a CR that rode in on a CRLF settings file —
  # using caret notation ("^M"), corrupting the JSON so the next read fails
  # with "malformed JSON" (#143/#138, same root cause as #102). writefile()
  # emits the bytes verbatim. See also strip's readfile() (#95).
  # Validate writefile()'s result, not just sqlite3's exit code. writefile()
  # returns the byte count written and yields NULL on a failed write (e.g. an
  # unwritable tmp dir) — but sqlite3 still exits 0, so an exit-code-only check
  # would mv an empty/partial tmp over the original. Compare the bytes written
  # to the content's byte length (CAST AS BLOB so multibyte content isn't
  # miscounted by character-based length()); anything but an exact match fails.
  # Guard contributed in #162 (kevinsj15).
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT coalesce(CASE
      WHEN json_extract(src.j, '\$.hooks.$event') IS NULL THEN
        src.j
      WHEN (SELECT count(*) FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
            WHERE NOT EXISTS (
              SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
              WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
            )) = 0 THEN
        json_remove(src.j, '\$.hooks.$event')
      ELSE
        json_set(src.j, '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
           WHERE NOT EXISTS (
             SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
             WHERE instr(json_extract(h.value, '\$.command'), '$SKILL_NAME') > 0
           ))
        )
    END, '') AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Wrap a POSIX shell command so Codex's Windows runner executes it through Git
# Bash. On native Windows, Codex runs each hook command via PowerShell, which
# cannot execute a bare POSIX ".sh" path, so the hook exits non-zero. Codex hook
# config supports a "commandWindows" key that takes precedence on Windows.
windows_wrap() {
  local posix_cmd="$1"
  local bash_cmd_ps
  bash_cmd_ps=$(printf '%s' "$posix_cmd" | sed "s/'/''/g")
  printf "\$b=\$env:GIT_BASH; if (-not \$b) { \$b=\$env:AGMSG_BASH }; if (-not \$b) { \$b='C:\\\\Program Files\\\\Git\\\\bin\\\\bash.exe' }; & \$b -lc '%s'" "$bash_cmd_ps"
}

# Build a native PowerShell hook command that only enqueues the event. The
# dispatcher later invokes Git Bash outside the Codex Windows sandbox.
windows_enqueue_wrap() {
  local event="$1"
  local type="$2"
  local project="$3"
  local enqueue_path="$SKILL_DIR/scripts/windows/hook-enqueue.ps1"
  if command -v cygpath >/dev/null 2>&1; then
    enqueue_path=$(cygpath -w "$enqueue_path" 2>/dev/null || printf '%s' "$enqueue_path")
  fi
  enqueue_path=$(printf '%s' "$enqueue_path" | sed "s/'/''/g")
  type=$(printf '%s' "$type" | sed "s/'/''/g")
  project=$(printf '%s' "$project" | sed "s/'/''/g")
  printf "& '%s' '%s' '%s' '%s'" "$enqueue_path" "$event" "$type" "$project"
}

# Append a single entry of the form {"matcher":"","hooks":[{"type":"command","command":"<cmd>"}]}
# to .hooks.<event> in the JSON at <path>, creating arrays/objects as needed.
# When the 4th arg is "yes" the entry carries the legacy Git Bash wrapper. When
# it is "queue", SessionStart/SessionEnd use the native enqueue transport. The
# caller supplies type/project as args 5/6 for that queue command.
# Writes the result back to <path>. As with strip_agmsg_event_file, the settings
# are read via readfile() rather than via argv (#95).
add_event_entry_file() {
  local path="$1"
  local event="$2"
  local cmd="$3"
  local windows_wrap="${4:-}"
  local hook_type="${5:-}"
  local hook_project="${6:-}"
  local sql_path
  sql_path=$(sql_readfile_path "$path")

  # Build the entry with SQLite's own json_object()/json_array() so SQLite does
  # every JSON-level escape. Raw values go in as ordinary SQL string literals
  # (single quotes doubled) — the only escaping this layer needs. Hand-building
  # the JSON string instead (and only escaping the codex commandWindows) left
  # the "command" value's embedded " and ' unescaped, producing "malformed
  # JSON" on tricky project paths and on native Windows sqlite builds (#134).
  local cmd_lit
  cmd_lit=$(printf '%s' "$cmd" | sed "s/'/''/g")
  local hook_obj="json_object('type','command','command','$cmd_lit'"
  if [ "$windows_wrap" = "yes" ]; then
    local cw cw_lit
    cw=$(windows_wrap "$cmd")
    cw_lit=$(printf '%s' "$cw" | sed "s/'/''/g")
    hook_obj="$hook_obj,'commandWindows','$cw_lit'"
  elif [ "$windows_wrap" = "queue" ]; then
    local queue_event cw cw_lit
    case "$event" in
      SessionStart) queue_event="session-start" ;;
      SessionEnd) queue_event="session-end" ;;
      *) queue_event="" ;;
    esac
    if [ -n "$queue_event" ]; then
      cw=$(windows_enqueue_wrap "$queue_event" "$hook_type" "$hook_project")
      cw_lit=$(printf '%s' "$cw" | sed "s/'/''/g")
      hook_obj="$hook_obj,'commandWindows','$cw_lit'"
    fi
  fi
  hook_obj="$hook_obj)"
  local entry_sql="json_object('matcher','','hooks',json_array($hook_obj))"

  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # writefile() instead of CLI redirect — see strip_agmsg_event_file for why
  # (strict sqlite3 caret-escapes control bytes in CLI output, #143/#102).
  # Validate writefile()'s byte count vs the content length — see
  # strip_agmsg_event_file for why the exit code alone is insufficient (#162).
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH base AS (
      SELECT CASE WHEN json_extract(readfile('$sql_path'), '\$.hooks') IS NULL
                  THEN json_set(readfile('$sql_path'), '\$.hooks', json('{}'))
                  ELSE readfile('$sql_path') END AS s
    ),
    out AS (SELECT CASE
      WHEN json_extract(s, '\$.hooks.$event') IS NULL THEN
        json_set(s, '\$.hooks.$event', json_array($entry_sql))
      ELSE
        json_set(s, '\$.hooks.$event',
          (SELECT json_group_array(json(v.value)) FROM (
             SELECT value FROM json_each(json_extract(s, '\$.hooks.$event'))
             UNION ALL
             SELECT $entry_sql
           ) v)
        )
    END AS blob FROM base)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}

# Drop the entire .hooks object if it ended up empty after stripping. Reads
# and writes <path> via readfile() — see strip_agmsg_event_file for the
# rationale (#95).
prune_empty_hooks_file() {
  local path="$1"
  local sql_path
  sql_path=$(sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(sql_readfile_path "$tmp")
  # writefile() instead of CLI redirect — see strip_agmsg_event_file (#143/#102).
  # Validate writefile()'s byte count vs the content length — see
  # strip_agmsg_event_file for why the exit code alone is insufficient (#162).
  local wrote
  wrote=$(agmsg_sqlite_mem "
    WITH src AS (SELECT readfile('$sql_path') AS j),
    out AS (SELECT coalesce(CASE
      WHEN json_extract(src.j, '\$.hooks') IS NULL THEN src.j
      WHEN (SELECT count(*) FROM json_each(json_extract(src.j, '\$.hooks'))) = 0 THEN
        json_remove(src.j, '\$.hooks')
      ELSE src.j
    END, '') AS blob FROM src)
    SELECT writefile('$tmp_sql', blob) = length(CAST(blob AS BLOB)) FROM out;
  ") || { rm -f "$tmp"; return 1; }
  [ "$wrote" = "1" ] || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$path"
}
