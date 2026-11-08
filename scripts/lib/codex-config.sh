#!/usr/bin/env bash
# Codex config selection is shared by installation, cleanup, and notices.
# An explicit CODEX_HOME isolates the profile: never also edit the default
# profile, including when testing a separate install (#1718).

# Prints the active profile config, falling back to Codex's default.
agmsg_codex_config_paths() {
  printf '%s/config.toml\n' "${CODEX_HOME:-$HOME/.codex}"
}

# Use the same native Windows path spelling for insertion and removal.
agmsg_codex_native_path() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1" 2>/dev/null || printf '%s\n' "$1"
  else
    printf '%s\n' "$1"
  fi
}

# Prints one writable_roots path per line for <skill_dir>: db/, teams/, run/,
# ext-tools/ and .install-op/ (the install operation lock, which a state move
# never touches, so it stays a real directory here) under it (or where their links point, when the state lives outside), in the SAME form install.sh's configure_codex_sandbox
# writes into Codex's config.toml. On Windows (MSYS2/Git Bash), $skill_dir is
# in MSYS form (/c/Users/...); Codex is a native Windows binary whose Rust
# path resolution cannot parse that (it resolves to a phantom C:\c\Users\...),
# so when cygpath is on PATH each path is converted to the mixed C:/Users/...
# form both the shell and Codex accept, before anything writes or greps for
# it. Kept in one place, alongside agmsg_codex_config_paths, so the writer
# (install.sh) and the reader (agmsg_codex_writable_roots_notice below) can
# never disagree about which form a path is in -- disagreeing here is exactly
# what made the notice fire "missing" forever on Windows even right after a
# correct `install --update` (#1483 review).
agmsg_codex_writable_paths() {
  local skill_dir="$1"
  local paths=("$skill_dir/db" "$skill_dir/teams" "$skill_dir/run" "$skill_dir/ext-tools" "$skill_dir/.install-op")
  local i real
  for i in "${!paths[@]}"; do
    # State kept outside the skills directory (scripts/lib/state-root.sh) is
    # reached through a link; Codex's sandbox checks the path a write resolves
    # to, so the entry has to name the real directory.
    if [ -L "${paths[$i]}" ] && real="$(cd -P "${paths[$i]}" 2>/dev/null && pwd -P)" && [ -n "$real" ]; then
      paths[$i]="$real"
    fi
    paths[$i]="$(agmsg_codex_native_path "${paths[$i]}")"
  done
  printf '%s\n' "${paths[@]}"
}

# Prints, one per line, the writable_roots entries an earlier release wrote for
# <skill_dir> that are now links into a state root (db/, teams/, run/,
# ext-tools/ under the skills directory itself, in the same form
# agmsg_codex_writable_paths writes). Codex refuses a writable root that
# contains a symlink, so an update that moved the state replaces these with the
# real paths. Nothing is printed for a part that is still a real directory.
agmsg_codex_stale_writable_paths() {
  local skill_dir="$1" part
  for part in db teams run ext-tools; do
    if [ -L "$skill_dir/$part" ]; then
      agmsg_codex_native_path "$skill_dir/$part"
    fi
  done
}

# agmsg_codex_roots_scan <config.toml>
#
# The one reader/editor of a Codex config.toml's writable_roots that install
# (update) and uninstall share. It reads the whole file by the TOML string rules
# (basic, literal and multi-line strings, comments, table headers), so only the
# real writable_roots array is looked at or edited: the same text inside a
# multi-line value elsewhere stays byte for byte. An element is compared by its
# decoded value, in whichever string spelling it is written. The result goes to
# stdout; the exit status says what changed: 10 nothing, 11 elements removed,
# 12 roots added, 13 both. The caller decides about backups and replacing.
#
# Environment: AGMSG_STALE_ROOTS (newline separated, exact paths to drop),
# AGMSG_STALE_PREFIXES (a path, or anything under it, is dropped),
# AGMSG_WANT_ROOTS (paths to add to [sandbox_workspace_write]'s array, which is
# created with the table when missing; arrays of other tables are never added
# to). Uninstall only takes its own elements out: an array left empty, and the
# table around it, stay as they are, so nothing of anyone else's is judged.
agmsg_codex_roots_scan() {
  awk '
    # position just after the closing delimiter of a multi-line string, or 0
    function msend(line, from, d,   k, ch) {
      for (k = from; k <= length(line); k++) {
        ch = substr(line, k, 1)
        if (d == "\"\"\"" && ch == "\\") { k++; continue }
        if (substr(line, k, 3) == d) return k + 3
      }
      return 0
    }
    # the value of a basic string body: \\ \" \t \n \r and \uXXXX for ASCII
    function dec(b,   o, k, ch, nx, h) {
      o = ""
      for (k = 1; k <= length(b); k++) {
        ch = substr(b, k, 1)
        if (ch != "\\") { o = o ch; continue }
        nx = substr(b, ++k, 1)
        if (nx == "t") o = o "\t"
        else if (nx == "n") o = o "\n"
        else if (nx == "r") o = o "\r"
        else if (nx == "u") {
          h = substr(b, k + 1, 4); k += 4
          if (h ~ /^00[0-7][0-9A-Fa-f]$/) o = o sprintf("%c", hexd(substr(h, 3, 1)) * 16 + hexd(substr(h, 4, 1)))
          else o = o "\\u" h
        }
        else o = o nx
      }
      return o
    }
    function hexd(x) { return index("0123456789abcdef", tolower(x)) - 1 }
    function isstale(v,   k) {
      if (v in stale) return 1
      for (k = 1; k <= np; k++) if (v == pre[k] || index(v, pre[k] "/") == 1) return 1
      return 0
    }
    BEGIN {
      n = split(ENVIRON["AGMSG_STALE_ROOTS"], st, "\n")
      for (i = 1; i <= n; i++) if (st[i] != "") stale[st[i]] = 1
      n = split(ENVIRON["AGMSG_STALE_PREFIXES"], sp, "\n")
      for (i = 1; i <= n; i++) if (sp[i] != "") pre[++np] = sp[i]
      m = split(ENVIRON["AGMSG_WANT_ROOTS"], wa, "\n")
      for (i = 1; i <= m; i++) if (wa[i] != "") want[++nw] = wa[i]
    }
    {
      gone = 0
      ed = 0
      start = 1
      # a table header outside any string or array
      if (!inr && ms == "" && $0 ~ /^[ \t]*\[\[?[^],=\[]+\]\]?[ \t\r]*(#.*)?$/) {
        intable = ($0 ~ /^[ \t]*\[[ \t]*sandbox_workspace_write[ \t]*\][ \t\r]*(#.*)?$/)
        if (intable && !basehdr) basehdr = nl + 1
      }
      if (inr) ed = 1
      else if (ms == "" && match($0, /^[ \t]*writable_roots[ \t]*=[ \t]*\[/)) {
        inr = 1; ed = 1; start = RLENGTH + 1
        narr++; arrbase[narr] = intable; arrline[narr] = nl + 1; arrpos[narr] = start - 1
      }
      len = length($0); out = substr($0, 1, start - 1); c = start
      while (c <= len) {
        if (ms != "") {
          p = msend($0, c, ms)
          if (p == 0) { out = out substr($0, c); break }
          out = out substr($0, c, p - c); c = p; ms = ""
          continue
        }
        ch = substr($0, c, 1)
        if (ch == "\"" || ch == "\x27") {
          if (substr($0, c, 3) == ch ch ch) {
            # a multi-line string; when it closes on this line it is one element too
            p = msend($0, c + 3, ch ch ch)
            if (p == 0) { ms = ch ch ch; out = out substr($0, c); break }
            tok = substr($0, c, p - c)
            body = substr(tok, 4, length(tok) - 6)
            val = (ch == "\"") ? dec(body) : body
            e = p - 1
          } else {
            # one whole string element; an escaped quote does not end a double-quoted one
            e = c + 1
            while (e <= len) {
              ec = substr($0, e, 1)
              if (ch == "\"" && ec == "\\") e++
              else if (ec == ch) break
              e++
            }
            tok = substr($0, c, e - c + 1)
            body = substr(tok, 2, length(tok) - 2)
            val = (ch == "\"") ? dec(body) : body
          }
          if (ed && isstale(val)) {
            c = e + 1
            if (match(substr($0, c), /^[ \t]*,[ \t]*/)) c += RLENGTH
            else if (substr($0, c) ~ /^[ \t]*\]/) sub(/[ \t]*,[ \t]*$/, "", out)   # the last one: no dangling comma
            gone = 1; removed = 1
            continue
          }
          if (ed) present[narr SUBSEP val] = 1
          out = out tok; c = e + 1
        } else if (ch == "#") {
          out = out substr($0, c); break
        } else if (ch == "]" && ed) {
          out = out substr($0, c); inr = 0; break
        } else { out = out ch; c++ }
      }
      if (!(gone && out ~ /^[ \t]*$/)) L[++nl] = out
    }
    END {
      # the array to add to: the one under [sandbox_workspace_write], and no other
      # (a profile table is left alone); without one it is created
      t = 0
      for (i = 1; i <= narr; i++) if (arrbase[i]) { t = i; break }
      for (i = 1; i <= nw; i++) if (!t || !((t SUBSEP want[i]) in present)) miss[++nm] = want[i]
      if (nm > 0) {
        added = 1
        if (t > 0) {
          ins = ""
          for (j = 1; j <= nm; j++) ins = ins "\"" miss[j] "\", "
          L[arrline[t]] = substr(L[arrline[t]], 1, arrpos[t]) ins substr(L[arrline[t]], arrpos[t] + 1)
        } else {
          ent = ""
          for (j = 1; j <= nm; j++) ent = ent (j > 1 ? ", " : "") "\"" miss[j] "\""
          if (basehdr) L[basehdr] = L[basehdr] "\nwritable_roots = [" ent "]"
          else { L[++nl] = ""; L[++nl] = "[sandbox_workspace_write]"; L[++nl] = "writable_roots = [" ent "]" }
        }
      }
      for (i = 1; i <= nl; i++) print L[i]
      exit 10 + (removed ? 1 : 0) + (added ? 2 : 0)
    }
  ' "$1"
}

# agmsg_codex_writable_roots_notice <skill_dir>
#
# Prints ONE line to stdout when a Codex config this install would write to
# (agmsg_codex_config_paths) exists but is missing any of this install's
# writable_roots entries (db/, teams/, run/, ext-tools/ under <skill_dir>) --
# the state left behind when Codex is installed AFTER agmsg (#1477):
# install.sh's own configure_codex_sandbox only ever writes these entries
# into a Codex config that already exists at install time, and nothing later
# adds them or says anything is missing. A sandboxed Codex session then has
# its writes under <skill_dir> silently refused.
#
# Read-only, on purpose: never edits the Codex config from here. That write
# may itself be refused from inside the same sandboxed session whose
# missing roots this is reporting, and rewriting a user's config out from
# under them without being asked is a separate, larger step than naming the
# fix. `install.sh --update` (or `npx agmsg install --update`) is the actual
# fix; this only says so, once, when it is true.
#
# Checked the SAME way configure_codex_sandbox itself decides "missing" --
# a literal `grep -q` for each path against the config file's raw text --
# so this can never disagree with what the installer would consider already
# done.
#
# A config file that does not exist at all is not reported: that is Codex
# not being installed (yet) on this profile, not this install's own gap
# (matches configure_codex_sandbox's own `[ -f "$code_config" ] || return 0`).
agmsg_codex_writable_roots_notice() {
  local skill_dir="$1"
  local writable_paths=()
  local _wp
  while IFS= read -r _wp; do
    writable_paths+=("$_wp")
  done < <(agmsg_codex_writable_paths "$skill_dir")
  unset _wp
  local cfg p incomplete
  while IFS= read -r cfg; do
    [ -f "$cfg" ] || continue
    incomplete=0
    for p in "${writable_paths[@]}"; do
      if ! grep -q "$p" "$cfg" 2>/dev/null; then
        incomplete=1
        break
      fi
    done
    if [ "$incomplete" -eq 1 ]; then
      printf "agmsg: Codex cannot write agmsg's data yet -- run 'npx agmsg install --update' once\n"
      return 0
    fi
  done < <(agmsg_codex_config_paths)
}
