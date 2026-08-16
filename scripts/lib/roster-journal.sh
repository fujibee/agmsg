#!/usr/bin/env bash
# Append-only member identity journal for the file-based team registry.
#
# The journal owns the answer to "which member id has this name?".
# config.json keeps a derived agents cache because existing readers consume that
# shape; registrations inside the cache remain machine-local and are never
# journaled.

[ -n "${_AGMSG_ROSTER_JOURNAL_SH:-}" ] && return 0
_AGMSG_ROSTER_JOURNAL_SH=1

if ! declare -F compat_uuid7 >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/compat.sh"
fi
if ! declare -F agmsg_write_atomic >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/registry-lock.sh"
fi
if ! declare -F agmsg_sql_readfile_path >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/sqlpath.sh"
fi

agmsg_roster_journal_path() {
  printf '%s/roster.jsonl\n' "$1"
}

agmsg_roster_has_journal() {
  [ -f "$(agmsg_roster_journal_path "$1")" ]
}

# For VALUES only — a name, a member id, a timestamp. A path bound for
# readfile() takes agmsg_sql_readfile_path instead: this doubles quotes and
# converts nothing, so on Git Bash sqlite got an MSYS path it could not open and
# join.sh exited 1 in silence after creating the team (#669). The two names read
# alike and do opposite things to a path, which is how the wrong one was picked.
_agmsg_roster_sqlesc() {
  printf '%s' "$1" | sed "s/'/''/g"
}

_agmsg_roster_record() {
  local type="$1" member_id="$2" name="$3" at="$4"
  sqlite3 :memory: "SELECT json_object(
    'type','$(_agmsg_roster_sqlesc "$type")',
    'id','$(compat_uuid7)',
    'member_id','$(_agmsg_roster_sqlesc "$member_id")',
    'name','$(_agmsg_roster_sqlesc "$name")',
    'at','$(_agmsg_roster_sqlesc "$at")'
  );" | tr -d '\r'
}

_agmsg_roster_rename_record() {
  local member_id="$1" from="$2" to="$3" at="$4"
  sqlite3 :memory: "SELECT json_object(
    'type','member_renamed',
    'id','$(compat_uuid7)',
    'member_id','$(_agmsg_roster_sqlesc "$member_id")',
    'from','$(_agmsg_roster_sqlesc "$from")',
    'to','$(_agmsg_roster_sqlesc "$to")',
    'at','$(_agmsg_roster_sqlesc "$at")'
  );" | tr -d '\r'
}

_agmsg_key_rotated_record() {
  local epoch="$1" key_id="$2" fingerprint="$3" at="$4"
  sqlite3 :memory: "SELECT json_object(
    'type','key_rotated',
    'id','$(compat_uuid7)',
    'epoch','$(_agmsg_roster_sqlesc "$epoch")',
    'key_id','$(_agmsg_roster_sqlesc "$key_id")',
    'fingerprint','$(_agmsg_roster_sqlesc "$fingerprint")',
    'at','$(_agmsg_roster_sqlesc "$at")'
  );" | tr -d '\r'
}

_agmsg_roster_append_record() {
  local team_dir="$1" record="$2" journal prior=""
  journal="$(agmsg_roster_journal_path "$team_dir")"
  [ -f "$journal" ] && prior="$(cat "$journal")"
  agmsg_write_atomic "$journal" "${prior:+$prior
}$record"
}

agmsg_roster_append_joined() {
  local team_dir="$1" member_id="$2" name="$3" at="$4" record
  record="$(_agmsg_roster_record member_joined "$member_id" "$name" "$at")" || return 1
  _agmsg_roster_append_record "$team_dir" "$record"
}

agmsg_roster_append_left() {
  local team_dir="$1" member_id="$2" name="$3" at="$4" record
  record="$(_agmsg_roster_record member_left "$member_id" "$name" "$at")" || return 1
  _agmsg_roster_append_record "$team_dir" "$record"
}

agmsg_roster_append_renamed() {
  local team_dir="$1" member_id="$2" from="$3" to="$4" at="$5" record
  record="$(_agmsg_roster_rename_record "$member_id" "$from" "$to" "$at")" || return 1
  _agmsg_roster_append_record "$team_dir" "$record"
}

agmsg_roster_append_key_rotated() {
  local team_dir="$1" epoch="$2" key_id="$3" fingerprint="$4" at="$5" record
  record="$(_agmsg_key_rotated_record "$epoch" "$key_id" "$fingerprint" "$at")" || return 1
  _agmsg_roster_append_record "$team_dir" "$record"
}

# Return the member that first claimed a name, including names retired by a
# leave or rename. Names are identity history and are never reassigned.
agmsg_roster_name_owner() {
  local team_dir="$1" name="$2" journal journal_sql name_sql
  journal="$(agmsg_roster_journal_path "$team_dir")"
  [ -f "$journal" ] || return 0
  journal_sql="$(agmsg_sql_readfile_path "$journal")"
  name_sql="$(_agmsg_roster_sqlesc "$name")"
  sqlite3 :memory: "
    WITH source(doc) AS (
      SELECT '[' || replace(
        rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10)),
        char(10), ',') || ']'
    ),
    records(ord,event) AS (
      SELECT CAST(key AS INTEGER),value FROM source,json_each(source.doc)
    ),
    bindings AS (
      SELECT ord,json_extract(event,'\$.member_id') AS member_id,
             CASE json_extract(event,'\$.type')
               WHEN 'member_joined' THEN json_extract(event,'\$.name')
               WHEN 'member_renamed' THEN json_extract(event,'\$.to')
             END AS name
        FROM records
       WHERE json_extract(event,'\$.type') IN ('member_joined','member_renamed')
    )
    SELECT member_id FROM bindings
     WHERE name='$name_sql' ORDER BY ord LIMIT 1;" 2>/dev/null | tr -d '\r'
}

# Start an id-bearing team journal from its current config. This is needed for
# teams created after ids landed but before this journal existed, and for a
# freshly pulled team whose initial roster came from the remote snapshot.
# Name-only legacy teams deliberately remain untouched until connect assigns
# their whole roster at once.
agmsg_roster_ensure() {
  local team_dir="$1" config="$2" journal config_sql team_id lines="" row name member_id at
  journal="$(agmsg_roster_journal_path "$team_dir")"
  [ -f "$journal" ] && return 0
  [ -f "$config" ] || return 0
  config_sql="$(agmsg_sql_readfile_path "$config")"
  team_id="$(sqlite3 :memory: \
    "SELECT COALESCE(json_extract(CAST(readfile('$config_sql') AS TEXT), '\$.team_id'),'');" \
    2>/dev/null | tr -d '\r')"
  [ -n "$team_id" ] || return 0
  at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  while IFS="$(printf '\t')" read -r name member_id; do
    [ -n "$name" ] && [ -n "$member_id" ] || continue
    row="$(_agmsg_roster_record member_joined "$member_id" "$name" "$at")" || return 1
    lines="${lines:+$lines
}$row"
  done <<EOF
$(sqlite3 -separator "$(printf '\t')" :memory: "
  SELECT key, COALESCE(json_extract(value, '\$.member_id'),'')
    FROM json_each(json_extract(
      CAST(readfile('$config_sql') AS TEXT), '\$.agents'))
   ORDER BY key;" 2>/dev/null | tr -d '\r')
EOF
  agmsg_write_atomic "$journal" "$lines"
}

# Rebuild $.agents from the journal while preserving the machine-local value
# (registrations and any compatibility fields) for the same member_id.
#
# Events are folded in journal order. A join claims a name permanently. A
# rename is a compare-and-swap: it applies only while `from` is the member's
# current active name and `to` has never belonged to another member. A leave
# applies only to the current active name. Rejected events remain audit facts
# but do not affect the projected roster.
agmsg_roster_project_config() {
  local team_dir="$1" config="$2" journal journal_sql config_sql updated
  journal="$(agmsg_roster_journal_path "$team_dir")"
  [ -f "$journal" ] || return 0
  [ -f "$config" ] || return 1
  # Readability is checked BEFORE the query, not after it comes back empty.
  #
  # Measured: with the journal unreadable and the config fine, this projection
  # does not return "" -- readfile(journal) is NULL, the fold sees no events,
  # and json_set() still builds a perfectly valid config from the readable one.
  # The result is a plausible document with an EMPTY roster, and the write below
  # would commit it. Diagnosing an empty result only would let that through: the
  # dangerous case is not the one that returns nothing, it is the one that
  # returns something believable.
  #
  # It costs two sqlite invocations per projection. That is the price of not
  # having the roster silently replaced by an empty one (#669).
  local f f_sql unreadable=0
  for f in "$journal" "$config"; do
    agmsg_sql_readfile_ok "$f" && continue
    unreadable=1
    f_sql="$(agmsg_sql_readfile_path "$f")"
    echo "agmsg: sqlite could not read '$f'." >&2
    # The converted form too: on Windows the difference between the two IS the
    # bug, and a reader who cannot see what sqlite was handed cannot see it.
    # Off Windows the two are the same string and this line is redundant --
    # cheap, beside a failure nobody could diagnose at all before.
    echo "agmsg: sqlite was given: $f_sql" >&2
  done
  if [ "$unreadable" -eq 1 ]; then
    # `[ -f ]` passed above, so the file is there and the OPEN is what failed.
    # Which open failure it was, this cannot say: the path form is the one that
    # brought us here (#669), and permissions, a lock, and I/O produce the same
    # NULL. Naming a cause the check did not establish sends the next reader
    # somewhere the evidence does not.
    echo "agmsg: the file is present, so the open failed, not the lookup --" >&2
    echo "agmsg: a path form a native sqlite3 cannot open (Git Bash's /tmp/...)," >&2
    echo "agmsg: or permissions, a lock, or an I/O error on the file itself." >&2
    echo "agmsg: refusing to project; the roster is left as it is." >&2
    return 1
  fi
  journal_sql="$(agmsg_sql_readfile_path "$journal")"
  config_sql="$(agmsg_sql_readfile_path "$config")"
  updated="$(sqlite3 :memory: "
    WITH
    source(doc) AS (
      SELECT CASE
        WHEN length(rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10))) = 0
          THEN '[]'
        ELSE '[' || replace(
          rtrim(CAST(readfile('$journal_sql') AS TEXT), char(10)),
          char(10), ',') || ']'
      END
    ),
    raw_records(physical_ord,event) AS (
      SELECT CAST(key AS INTEGER), value FROM source, json_each(source.doc)
    ),
    sync_order AS (
      SELECT json_extract(event,'\$.mutation_id') AS mutation_id,
             MIN(CAST(json_extract(event,'\$.server_seq') AS INTEGER)) AS server_seq
        FROM raw_records
       WHERE json_extract(event,'\$.type')='roster_synced'
       GROUP BY json_extract(event,'\$.mutation_id')
    ),
    records(ord,event) AS (
      SELECT row_number() OVER (
               ORDER BY CASE WHEN s.server_seq IS NULL THEN 1 ELSE 0 END,
                        s.server_seq,r.physical_ord
             ) - 1,
             r.event
        FROM raw_records r
        LEFT JOIN sync_order s
          ON s.mutation_id=json_extract(r.event,'\$.id')
       WHERE json_extract(r.event,'\$.type')
             IN ('member_joined','member_left','member_renamed')
    ),
    normalized AS (
      SELECT ord,json_extract(event,'\$.type') AS type,
             json_extract(event,'\$.member_id') AS member_id,
             json_extract(event,'\$.name') AS name,
             json_extract(event,'\$.from') AS old_name,
             json_extract(event,'\$.to') AS new_name
        FROM records
    ),
    fold(ord,owners,current_names,active) AS (
      SELECT -1,json_object(),json_object(),json_object()
      UNION ALL
      SELECT n.ord,
        CASE
          WHEN n.type='member_joined'
           AND (json_extract(f.owners,'\$.' || json_quote(n.name)) IS NULL
             OR (json_extract(f.owners,'\$.' || json_quote(n.name))=n.member_id
               AND json_extract(f.active,'\$.' || json_quote(n.member_id))=0
               AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.name))
            THEN json_set(f.owners,'\$.' || json_quote(n.name),n.member_id)
          WHEN n.type='member_renamed'
           AND json_extract(f.active,'\$.' || json_quote(n.member_id))=1
           AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.old_name
           AND COALESCE(json_extract(f.owners,'\$.' || json_quote(n.new_name)),
                        n.member_id)=n.member_id
            THEN json_set(f.owners,'\$.' || json_quote(n.new_name),n.member_id)
          ELSE f.owners
        END,
        CASE
          WHEN n.type='member_joined'
           AND (json_extract(f.owners,'\$.' || json_quote(n.name)) IS NULL
             OR (json_extract(f.owners,'\$.' || json_quote(n.name))=n.member_id
               AND json_extract(f.active,'\$.' || json_quote(n.member_id))=0
               AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.name))
            THEN json_set(f.current_names,'\$.' || json_quote(n.member_id),n.name)
          WHEN n.type='member_renamed'
           AND json_extract(f.active,'\$.' || json_quote(n.member_id))=1
           AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.old_name
           AND COALESCE(json_extract(f.owners,'\$.' || json_quote(n.new_name)),
                        n.member_id)=n.member_id
            THEN json_set(f.current_names,'\$.' || json_quote(n.member_id),n.new_name)
          ELSE f.current_names
        END,
        CASE
          WHEN n.type='member_joined'
           AND (json_extract(f.owners,'\$.' || json_quote(n.name)) IS NULL
             OR (json_extract(f.owners,'\$.' || json_quote(n.name))=n.member_id
               AND json_extract(f.active,'\$.' || json_quote(n.member_id))=0
               AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.name))
            THEN json_set(f.active,'\$.' || json_quote(n.member_id),1)
          WHEN n.type='member_left'
           AND json_extract(f.active,'\$.' || json_quote(n.member_id))=1
           AND json_extract(f.current_names,'\$.' || json_quote(n.member_id))=n.name
            THEN json_set(f.active,'\$.' || json_quote(n.member_id),0)
          ELSE f.active
        END
      FROM fold f JOIN normalized n ON n.ord=f.ord+1
    ),
    final AS (
      SELECT owners,current_names,active FROM fold ORDER BY ord DESC LIMIT 1
    ),
    existing AS (
      SELECT key AS name,value,
             json_extract(value,'\$.member_id') AS member_id
        FROM json_each(json_extract(
          CAST(readfile('$config_sql') AS TEXT), '\$.agents'))
    ),
    projected AS (
      SELECT c.value AS name,c.key AS member_id,
             COALESCE(
               (SELECT e.value FROM existing e
                 WHERE e.member_id=c.key LIMIT 1),
               (SELECT json_set(e.value,'\$.member_id',c.key)
                  FROM existing e
                 WHERE e.name=c.value LIMIT 1),
               json_object('member_id',c.key,'registrations',json_array())
             ) AS agent
        FROM final f,json_each(f.current_names) c
       WHERE json_extract(f.active,'\$.' || json_quote(c.key))=1
         AND json_extract(f.owners,'\$.' || json_quote(c.value))=c.key
    ),
    agents(value) AS (
      SELECT COALESCE(json_group_object(name,json(agent)),json_object())
        FROM projected
    ),
    retired(value) AS (
      SELECT COALESCE(json_group_object(c.value,
               json(json_object('member_id',c.key))),json_object())
        FROM final f,json_each(f.current_names) c
       WHERE json_extract(f.active,'\$.' || json_quote(c.key))=0
         AND json_extract(f.owners,'\$.' || json_quote(c.value))=c.key
    )
    SELECT json_set(CAST(readfile('$config_sql') AS TEXT),
                    '\$.agents',json(agents.value),
                    '\$.retired_members',json(retired.value))
      FROM agents,retired;" 2>/dev/null | tr -d '\r')" || return 1
  # Empty, after the precheck above already said both files open. Before #669
  # this line was a bare `return 1` and every way of arriving here looked the
  # same: join.sh printed "Created team:" and exited with nothing on stderr.
  #
  # The precheck is not repeated here for its own sake -- it passed. It is asked
  # again because "it opened a moment ago" and "it opens now" are different
  # claims: a lock, a permission change, or an unmounted volume between the two
  # would land exactly here, and that failure deserves the open-failure message
  # rather than being reported as bad journal contents. When both still open,
  # the contents are what is left.
  if [ -z "$updated" ]; then
    local f f_sql named=0
    for f in "$journal" "$config"; do
      agmsg_sql_readfile_ok "$f" && continue
      named=1
      f_sql="$(agmsg_sql_readfile_path "$f")"
      echo "agmsg: sqlite could not read '$f'." >&2
      # The converted form too: on Windows the difference between the two IS
      # the bug, and a reader who cannot see what sqlite was handed cannot see
      # it. Off Windows they are the same string and this line is redundant --
      # cheap, next to a failure nobody could diagnose at all before.
      echo "agmsg: sqlite was given: $f_sql" >&2
    done
    if [ "$named" -eq 1 ]; then
      # It opened for the precheck and does not open now, so this is a change
      # under us -- a lock, a mode change, a volume going away. Which one, this
      # cannot say, and it does not guess.
      echo "agmsg: it opened moments ago and does not now -- something changed" >&2
      echo "agmsg: under the run: a lock, permissions, or the volume." >&2
    else
      # Both readable, still nothing. A different failure, and it gets its own
      # sentence rather than borrowing the one above -- saying "could not read"
      # about a file that was read is how the next person loses an afternoon.
      echo "agmsg: the roster projection produced no config for '$config'." >&2
      echo "agmsg: both files were readable, so this is the journal's contents." >&2
    fi
    return 1
  fi
  agmsg_write_atomic "$config" "$updated"
}
