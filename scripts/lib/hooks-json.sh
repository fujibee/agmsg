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
# Sourced by delivery.sh AFTER it defines SKILL_DIR (used to detect
# agmsg-owned entries); the existing lib convention is for sourced modules to
# reference caller-set globals rather than re-resolve them.

# This file used to carry its own copy of the path converter. One definition
# now, in lib/sqlpath.sh — see the note there for why a second copy is worse
# than no copy (#669).
if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/sqlpath.sh"
fi

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
  sql_path=$(agmsg_sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(agmsg_sql_readfile_path "$tmp")
  # Ownership is decided against the absolute install directory, not the bare
  # skill name (#1038): a project's OWN hook whose command happens to contain
  # the substring "agmsg" -- a natural name for a hook that cooperates with
  # this tool -- used to match `instr(command, '$SKILL_NAME')` and get
  # silently stripped alongside agmsg's real entries. $SKILL_DIR is this
  # install's own absolute path; every command agmsg ever writes invokes a
  # script under it, and nothing legitimately outside agmsg's install would
  # ever contain that exact path as a substring.
  local skill_dir_sql
  skill_dir_sql=$(printf '%s' "$SKILL_DIR" | sed "s/'/''/g")
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
              WHERE instr(json_extract(h.value, '\$.command'), '$skill_dir_sql') > 0
            )) = 0 THEN
        json_remove(src.j, '\$.hooks.$event')
      ELSE
        json_set(src.j, '\$.hooks.$event',
          (SELECT json_group_array(json(s.value))
           FROM json_each(json_extract(src.j, '\$.hooks.$event')) AS s
           WHERE NOT EXISTS (
             SELECT 1 FROM json_each(json_extract(s.value, '\$.hooks')) AS h
             WHERE instr(json_extract(h.value, '\$.command'), '$skill_dir_sql') > 0
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
#
# The shell stays a LOGIN shell, and the payload no longer travels on its stdout
# (#1015). `-l` reads the profile chain, and everything the profile prints goes
# to that same stdout, ahead of the JSON -- codex parses the whole stream as one
# document, so one line of profile chatter makes the payload unparseable, and by
# then the hook has already consumed the rows. Measured on macOS and Linux as
# well as reported on Windows: the mechanism is bash's, not Windows's.
#
# Dropping `-l` would close it and was the first plan. Measured instead: with a
# profile that exports a PATH the command needs, the non-login shell cannot find
# the tool and the hook exits without emitting anything. That trades a silent
# loss for a total one, and only under a premise nobody has measured -- whether a
# given Git Bash profile provides something the hook relies on. Keeping `-l`
# needs no such premise.
#
# So: bash writes the command's own stdout to a file, PowerShell -- which read no
# profile -- prints the file, and the login shell's stdout is discarded. The
# braces are there so the redirect covers the whole command however it is
# composed, not just its last element. The exit status is carried across
# explicitly; without it the hook would report on `Remove-Item`.
#
# No `\"` anywhere in what is emitted: PowerShell reads a backslash-escaped
# quote as a literal backslash and ends the string there (see the codex
# template's warning).
windows_wrap() {
  local posix_cmd="$1"
  local bash_cmd_ps
  bash_cmd_ps=$(printf '%s' "{ $posix_cmd ; } > \"\$AGMSG_HOOK_OUT\"" | sed "s/'/''/g")
  # `printf '%s'`, never a format string. This text carries backslashes into
  # PowerShell, and a format string puts a second round of escape processing
  # between what is written here and what is emitted -- measured: three attempts
  # at `Replace('\','/')` through a format emitted `\\`, `\` and then nothing,
  # and only the last one was visible as wrong. One layer, and the layer is
  # bash's own double-quote rules.
  printf '%s' "\$b=\$env:GIT_BASH; if (-not \$b) { \$b=\$env:AGMSG_BASH }; if (-not \$b) { \$b='C:\\Program Files\\Git\\bin\\bash.exe' }; \$o=[IO.Path]::GetTempFileName(); \$s=[IO.Path]::GetTempFileName(); [IO.File]::WriteAllText(\$s,'$bash_cmd_ps',(New-Object System.Text.UTF8Encoding \$false)); \$env:AGMSG_HOOK_OUT=\$o; & \$b -l (\$s.Replace('\\','/')) | Out-Null; \$rc=\$LASTEXITCODE; Get-Content -Raw -LiteralPath \$o; Remove-Item -Force -LiteralPath \$o,\$s -ErrorAction SilentlyContinue; exit \$rc"
}

# Append a single entry of the form {"matcher":"","hooks":[{"type":"command","command":"<cmd>"}]}
# to .hooks.<event> in the JSON at <path>, creating arrays/objects as needed.
# When the 4th arg is "yes" the entry also carries a "commandWindows" so the hook
# runs on native Windows; otherwise it is omitted. This layer stays type-agnostic
# — the caller (delivery.sh) decides from the type manifest whether to wrap.
# Writes the result back to <path>. As with strip_agmsg_event_file, the settings
# are read via readfile() rather than via argv (#95).
add_event_entry_file() {
  local path="$1"
  local event="$2"
  local cmd="$3"
  local windows_wrap="${4:-}"
  local sql_path
  sql_path=$(agmsg_sql_readfile_path "$path")

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
  fi
  hook_obj="$hook_obj)"
  local entry_sql="json_object('matcher','','hooks',json_array($hook_obj))"

  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(agmsg_sql_readfile_path "$tmp")
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

# Detect the indent unit an existing pretty-printed JSON file uses, taken
# from its own SECOND line: the first line of anything this codebase or a
# human writes by hand is the opening brace alone, so the second line's
# leading whitespace run (if any) IS the indent unit, verbatim -- a file
# indented with tabs is matched with tabs, not assumed to be spaces. Prints
# nothing and returns 1 when <path> does not exist, has fewer than two
# lines, or its second line has no leading whitespace (already
# minified/compact) -- callers treat "no indent detected" as "leave the
# content exactly as this function's caller already built it" (#1429).
_agmsg_json_detect_indent() {
  local path="$1" line2
  [ -f "$path" ] || return 1
  line2=$(sed -n '2p' "$path" 2>/dev/null)
  [ -n "$line2" ] || return 1
  case "$line2" in
    [\ $'\t']*) ;;
    *) return 1 ;;
  esac
  printf '%s' "${line2%%[!\ $'\t']*}"
}

# Do <a> and <b> hold the same JSON content, ignoring formatting (key/array
# layout, whitespace, indentation)? Compares each file's sqlite json()
# (compact, canonical) rendering as a string, not raw bytes -- an existing
# hooks_file a human hand-formatted differently from what this codebase
# writes (or pretty-printed some other way) must still compare equal to an
# unchanged registration, or the very first `set` after adopting this
# comparison would trigger one spurious rewrite (#1429 review). `json()` has
# been part of every SQLite build with the json1 extension since its
# original release (3.9.0) -- well below json_pretty's 3.46.0 floor -- so
# unlike _agmsg_json_pretty_supported below, this needs no availability
# probe or degrade path: the extension is already a hard dependency of this
# file's other functions.
#
# Any sqlite error (e.g. either file holds invalid JSON) is treated as "not
# equal" -- falls through to the normal write path, the same behavior this
# codebase had before this comparison existed.
_agmsg_json_content_equal() {
  local a="$1" b="$2"
  local a_sql b_sql result
  a_sql=$(agmsg_sql_readfile_path "$a")
  b_sql=$(agmsg_sql_readfile_path "$b")
  result=$(agmsg_sqlite_mem "
    SELECT CASE WHEN json(readfile('$a_sql')) = json(readfile('$b_sql'))
           THEN 1 ELSE 0 END;
  ") || return 1
  [ "$result" = "1" ]
}

# 0 iff this sqlite3 build's json1 extension has json_pretty (added in
# SQLite 3.46.0; this project's own floor is unversioned -- see README,
# "requires sqlite3" with no minimum stated). Probed once per process and
# cached: calling the function and checking whether it errors answers
# exactly the question that matters here, without parsing a version string
# that describes the CLI, not necessarily the linked json1 build.
_agmsg_json_pretty_supported() {
  if [ -z "${_AGMSG_JSON_PRETTY_SUPPORTED:-}" ]; then
    if agmsg_sqlite_mem "SELECT json_pretty('{}');" >/dev/null 2>&1; then
      _AGMSG_JSON_PRETTY_SUPPORTED=yes
    else
      _AGMSG_JSON_PRETTY_SUPPORTED=no
    fi
  fi
  [ "$_AGMSG_JSON_PRETTY_SUPPORTED" = yes ]
}

# Rewrite <tmp> IN PLACE (same path) to json_pretty-format its content with
# <indent> as the indent unit. A no-op, successfully, when json_pretty is
# not supported (_agmsg_json_pretty_supported) -- a caller that always
# calls this and then compares bytes against the original gets today's
# plain/compact behavior on a build without json_pretty, not an error, and
# not a behavior this project's stated floor ("requires sqlite3", no
# version pinned) does not actually guarantee.
_agmsg_json_reindent() {
  local tmp="$1" indent="$2"
  _agmsg_json_pretty_supported || return 0
  local tmp2 tmp2_sql tmp_sql wrote indent_sql
  tmp_sql=$(agmsg_sql_readfile_path "$tmp")
  tmp2=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp2_sql=$(agmsg_sql_readfile_path "$tmp2")
  indent_sql=$(printf '%s' "$indent" | sed "s/'/''/g")
  wrote=$(agmsg_sqlite_mem "
    WITH src AS (SELECT json_pretty(readfile('$tmp_sql'), '$indent_sql') AS blob)
    SELECT writefile('$tmp2_sql', blob) = length(CAST(blob AS BLOB)) FROM src;
  ") || wrote=""
  if [ "$wrote" = "1" ]; then
    mv "$tmp2" "$tmp"
  else
    rm -f "$tmp2"
  fi
  return 0
}

# Drop the entire .hooks object if it ended up empty after stripping. Reads
# and writes <path> via readfile() — see strip_agmsg_event_file for the
# rationale (#95).
prune_empty_hooks_file() {
  local path="$1"
  local sql_path
  sql_path=$(agmsg_sql_readfile_path "$path")
  local tmp tmp_sql
  tmp=$(mktemp "${TMPDIR:-/tmp}/agmsg.XXXXXX")
  tmp_sql=$(agmsg_sql_readfile_path "$tmp")
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
