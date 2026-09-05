import argparse
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import time
import uuid


BINDING = ["perf", "018f3f7e-0000-7000-8000-000000000000",
           "018f3f7e-0000-7000-8000-000000000001", "1"]


def backup(source, destination):
    with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as original:
        with sqlite3.connect(destination) as target:
            original.backup(target)


def environment(skill, directory):
    result = {key: value for key, value in os.environ.items() if not key.startswith("AGMSG_")}
    result.update(HOME=str(skill / "home"), SKILL_DIR=str(skill),
                  AGMSG_STORAGE_DRIVER="sqlite", AGMSG_STORAGE_PATH=str(directory))
    return result


def apply(skill, directory, page, extra=None):
    settings = environment(skill, directory)
    settings.update(extra or {})
    started = time.perf_counter()
    result = subprocess.run(
        ["bash", str(skill / "scripts/internal/storage-sync-driver.sh"), "apply", *BINDING],
        input=page, text=True, capture_output=True, env=settings, check=True,
    )
    elapsed = time.perf_counter() - started
    outcomes = [json.loads(line) for line in result.stdout.splitlines()]
    assert not any(record.get("corrupt_count", 0) for record in outcomes)
    return elapsed


def seed(skill, directory, width, count, preloaded):
    directory.mkdir()
    apply(skill, directory, '{"type":"sync_pull_cursor","next_after":"0"}\n')
    database = directory / "messages.db"
    records = []
    with sqlite3.connect(database) as connection:
        binding = connection.execute(
            "SELECT local_team,server_instance_id,remote_team_id,protocol_version,"
            "driver_generation FROM sync_bindings"
        ).fetchone()
        for position in range(1, preloaded + 1):
            local_id = f"fixture-{position}"
            connection.execute(
                "INSERT INTO events(seq,type,id,team,from_agent,to_agent,body,at,legacy_id) "
                "VALUES (?,'message_sent',?,'perf','sender','receiver',?,'2026-01-01',?)",
                (position, local_id, "p" * 120, position),
            )
            connection.execute(
                "INSERT INTO messages(id,team,from_agent,to_agent,body,created_at) "
                "VALUES (?,'perf','sender','receiver',?,'2026-01-01')",
                (position, "p" * 120),
            )
            connection.execute(
                "INSERT INTO sync_messages(local_team,server_instance_id,remote_team_id,"
                "protocol_version,driver_generation,local_position,local_id,wire_id,"
                "envelope_v,cipher,key_id,blob,server_seq,direction) "
                "VALUES (?,?,?,?,?,?,?,?,1,'age-v1','fixture-key',?,?,'pull')",
                (*binding, position, local_id, str(uuid.UUID(int=position, version=4)),
                 "p" * 4096, str(position)),
            )
        for position in range(preloaded + 1, preloaded + count + 1):
            blob = (f"blob-{position:08d}-" + "x" * width)[:width]
            wire = str(uuid.UUID(int=position, version=4))
            connection.execute(
                "INSERT INTO sync_quarantine(local_team,server_instance_id,remote_team_id,"
                "protocol_version,driver_generation,server_seq,wire_id,server_received_at,"
                "envelope_v,cipher,key_id,blob,status) "
                "VALUES (?,?,?,?,?,?,?,'2026-01-01',1,'age-v1','fixture-key',?,'pending_key')",
                (*binding, str(position), wire, blob),
            )
            records.append({
                "type": "sync_pull_message", "server_seq": str(position), "id": wire,
                "server_received_at": "2026-01-01",
                "envelope": {"v": 1, "cipher": "age-v1", "key_id": "fixture-key", "blob": blob},
                "status": "importable", "projection": {
                    "from_agent": "sender", "to_agent": "receiver", "body": "b" * 120,
                    "created_at": "2026-01-01",
                },
            })
        connection.execute("UPDATE sync_bindings SET transport_cursor=?", (str(preloaded + count),))
        connection.commit()
    records.append({"type": "sync_pull_cursor", "next_after": str(preloaded + count)})
    return database, records, "".join(json.dumps(record) + "\n" for record in records)


def verify(database, records, preloaded):
    with sqlite3.connect(database) as connection:
        for record in records[:-1]:
            blob, status = connection.execute(
                "SELECT blob,status FROM sync_quarantine WHERE wire_id=?", (record["id"],)
            ).fetchone()
            assert (blob, status) == (record["envelope"]["blob"], "imported")
            mapped = connection.execute(
                "SELECT blob FROM sync_messages WHERE wire_id=?", (record["id"],)
            ).fetchone()[0]
            assert mapped == blob
        expected = preloaded + len(records) - 1
        for table in ("events", "messages", "sync_messages"):
            assert connection.execute(f"SELECT count(*) FROM {table}").fetchone()[0] == expected
        assert connection.execute(
            "SELECT count(*) FROM events e JOIN messages m ON m.id=e.legacy_id WHERE e.body=m.body"
        ).fetchone()[0] == expected


def main():
    parser = argparse.ArgumentParser(description="Synthetic post-decryption apply cost and SQL-byte comparison")
    parser.add_argument("--baseline", type=Path, required=True, help="Baseline checkout or archive directory")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=5)
    parser.add_argument("--messages", type=int, default=100)
    parser.add_argument("--preloaded", type=int, default=1000)
    parser.add_argument("--blob-bytes", default="120,4096,16384")
    args = parser.parse_args()
    widths = list(map(int, args.blob_bytes.split(",")))
    if not 1 <= args.messages <= 1000 or args.preloaded < 0 or args.repetitions < 1 or min(widths) < 16:
        parser.error("Require 1..1000 messages, nonnegative preloaded rows, positive repetitions, and blobs >=16 bytes")
    args.out = args.out.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    skills = {}
    for name, source in [("before", args.baseline), ("after", Path(__file__).resolve().parents[2])]:
        skill = args.out / name
        shutil.copytree(source / "scripts", skill / "scripts")
        (skill / "home").mkdir()
        skills[name] = skill
    real_sqlite = shutil.which("sqlite3")
    probe = args.out / "probe"
    probe.mkdir()
    wrapper = probe / "sqlite3"
    wrapper.write_text('#!/usr/bin/env bash\n'
                       'for argument in "$@"; do\n'
                       '  if [ "$argument" = -bail ]; then\n'
                       '    cat > "$APPLY_SQL_CAPTURE"\n'
                       '    exec "$REAL_SQLITE" "$@" < "$APPLY_SQL_CAPTURE"\n'
                       '  fi\n'
                       'done\n'
                       'exec "$REAL_SQLITE" "$@"\n')
    wrapper.chmod(0o755)
    metadata = {"sqlite": subprocess.check_output([real_sqlite, "--version"], text=True).strip(),
                "python_sqlite_fixture_only": sqlite3.sqlite_version,
                "messages": args.messages, "preloaded": args.preloaded}
    (args.out / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    for width in widths:
        source, records, page = seed(skills["before"], args.out / f"seed-{width}",
                                     width, args.messages, args.preloaded)
        sql_files = {}
        for name, skill in skills.items():
            directory = args.out / f"capture-{width}-{name}"
            directory.mkdir()
            backup(source, directory / "messages.db")
            sql_file = directory / "apply.sql"
            apply(skill, directory, page, {"PATH": str(probe) + os.pathsep + os.environ["PATH"],
                                          "REAL_SQLITE": real_sqlite, "APPLY_SQL_CAPTURE": str(sql_file)})
            verify(directory / "messages.db", records, args.preloaded)
            sql_files[name] = sql_file
        for repetition in range(args.repetitions):
            names = list(skills) if repetition % 2 == 0 else list(skills)[::-1]
            for name in names:
                directory = args.out / f"run-{width}-{repetition}-{name}"
                directory.mkdir()
                database = directory / "messages.db"
                backup(source, database)
                elapsed = apply(skills[name], directory, page)
                verify(database, records, args.preloaded)
                apply(skills[name], directory, page)
                verify(database, records, args.preloaded)
                replay_db = directory / "sql-only.db"
                backup(source, replay_db)
                with sql_files[name].open("rb") as sql_input:
                    started = time.perf_counter()
                    subprocess.run([real_sqlite, "-bail", str(replay_db)], stdin=sql_input,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, check=True)
                    sql_elapsed = time.perf_counter() - started
                verify(replay_db, records, args.preloaded)
                sql_text = sql_files[name].read_text()
                result = {"variant": name, "blob_bytes": width, "repetition": repetition,
                          "apply_ms_per_message": elapsed * 1000 / args.messages,
                          "sqlite_batch_ms_per_message": sql_elapsed * 1000 / args.messages,
                          "sql_bytes": sql_files[name].stat().st_size,
                          "first_blob_copies": sql_text.count(records[0]["envelope"]["blob"])}
                with (args.out / "results.jsonl").open("a") as report:
                    report.write(json.dumps(result) + "\n")
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
