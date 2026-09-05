import argparse
import ctypes
import json
from pathlib import Path
import sqlite3
import time


def load_library(path):
    library = ctypes.CDLL(str(path))
    pointer = ctypes.c_void_p
    library.sqlite3_open_v2.argtypes = [ctypes.c_char_p, ctypes.POINTER(pointer), ctypes.c_int, ctypes.c_char_p]
    library.sqlite3_prepare_v2.argtypes = [pointer, pointer, ctypes.c_int,
                                         ctypes.POINTER(pointer), ctypes.POINTER(pointer)]
    for name in ("sqlite3_step", "sqlite3_finalize", "sqlite3_close"):
        getattr(library, name).argtypes = [pointer]
    library.sqlite3_errmsg.argtypes = [pointer]
    library.sqlite3_errmsg.restype = ctypes.c_char_p
    library.sqlite3_libversion.restype = ctypes.c_char_p
    return library


def profile(library, database, sql):
    connection = ctypes.c_void_p()
    status = library.sqlite3_open_v2(str(database).encode(), ctypes.byref(connection), 2, None)
    if status:
        library.sqlite3_close(connection)
        raise RuntimeError(f"sqlite3_open_v2: {status}")
    buffer = ctypes.create_string_buffer(sql)
    start_address = ctypes.addressof(buffer)
    offset = 0
    totals = dict(prepare_ms=0.0, step_ms=0.0, finalize_ms=0.0, statements=0)
    try:
        while offset < len(sql):
            statement = ctypes.c_void_p()
            tail = ctypes.c_void_p()
            started = time.perf_counter()
            status = library.sqlite3_prepare_v2(connection, start_address + offset,
                                                len(sql) - offset + 1,
                                                ctypes.byref(statement), ctypes.byref(tail))
            totals["prepare_ms"] += (time.perf_counter() - started) * 1000
            if status:
                if statement.value:
                    library.sqlite3_finalize(statement)
                raise RuntimeError(library.sqlite3_errmsg(connection).decode())
            next_offset = tail.value - start_address
            if next_offset <= offset:
                raise RuntimeError("SQLite parser did not advance")
            offset = next_offset
            if not statement.value:
                continue
            totals["statements"] += 1
            try:
                started = time.perf_counter()
                status = library.sqlite3_step(statement)
                while status == 100:
                    status = library.sqlite3_step(statement)
                totals["step_ms"] += (time.perf_counter() - started) * 1000
                if status != 101:
                    raise RuntimeError(library.sqlite3_errmsg(connection).decode())
            finally:
                started = time.perf_counter()
                final_status = library.sqlite3_finalize(statement)
                totals["finalize_ms"] += (time.perf_counter() - started) * 1000
            if final_status:
                raise RuntimeError(f"sqlite3_finalize: {final_status}")
    finally:
        library.sqlite3_close(connection)
    return totals


def main():
    parser = argparse.ArgumentParser(description="Prepare/step profile of synthetic apply-blob.py captures")
    parser.add_argument("--run", type=Path, required=True)
    parser.add_argument("--library", type=Path, required=True, help="SQLite shared library matching the measured CLI")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--repetitions", type=int, default=20)
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("Require positive repetitions")
    args.run = args.run.resolve()
    args.out.mkdir(parents=True, exist_ok=False)
    metadata = json.loads((args.run / "metadata.json").read_text())
    library = load_library(args.library)
    version = library.sqlite3_libversion().decode()
    if version != metadata["sqlite"].split()[0]:
        parser.error("Shared library version must match the measured sqlite3 CLI")
    for seed in sorted(args.run.glob("seed-*")):
        width = int(seed.name.split("-")[1])
        for repetition in range(args.repetitions):
            names = ["before", "after"] if repetition % 2 == 0 else ["after", "before"]
            for name in names:
                database = args.out / f"{width}-{repetition}-{name}.db"
                with sqlite3.connect((seed / "messages.db").as_uri() + "?mode=ro", uri=True) as source:
                    with sqlite3.connect(database) as target:
                        source.backup(target)
                sql = (args.run / f"capture-{width}-{name}" / "apply.sql").read_bytes()
                result = profile(library, database, sql)
                with sqlite3.connect(database) as connection:
                    expected = metadata["preloaded"] + metadata["messages"]
                    assert connection.execute("SELECT count(*) FROM messages").fetchone()[0] == expected
                    assert connection.execute(
                        "SELECT count(*) FROM sync_quarantine WHERE status='imported'"
                    ).fetchone()[0] == metadata["messages"]
                    assert connection.execute(
                        "SELECT count(*) FROM sync_quarantine q JOIN sync_messages m ON q.wire_id=m.wire_id "
                        "WHERE q.blob=m.blob"
                    ).fetchone()[0] == metadata["messages"]
                result.update(blob_bytes=width, variant=name, repetition=repetition, sqlite=version)
                with (args.out / "results.jsonl").open("a") as report:
                    report.write(json.dumps(result) + "\n")
                print(json.dumps(result), flush=True)


if __name__ == "__main__":
    main()
