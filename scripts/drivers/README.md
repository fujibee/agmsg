# delivery drivers (skeleton — #48)

Per-agent-type delivery drivers, dispatched by `delivery.sh`. This is a **WIP
skeleton** to make the #48 refactor concrete — only the **rule-file class**
(`gemini`, `antigravity`) is wired through the dispatcher so far; `claude-code` /
`codex` / `copilot` still run on the legacy in-`delivery.sh` paths (see the
`TODO(#48)` markers there). Behavior is unchanged and the bats suite stays green.

## Contract

`delivery.sh` looks up `scripts/drivers/<type>.sh`; if it exists, it sources it
and calls the verbs below. A driver runs in `delivery.sh`'s environment, so it
may use `resolve_hooks_file()`, `SKILL_DIR`, `SKILL_NAME`, etc.

| verb | signature | returns |
|---|---|---|
| `agmsg_driver_apply` | `<type> <project> <mode>` | writes/removes this runtime's hook/rule config for `mode` |
| `agmsg_driver_status` | `<type> <project>` | echoes the current mode (e.g. `turn` / `off`) |

A type with no `drivers/<type>.sh` falls through to the legacy path — so the
extraction can land class by class without a flag day.

## Classes

Most runtimes collapse onto a shared class lib (`_<class>.sh`); the per-type
file just supplies its identity:

- **rule-file** (`_rulefile.sh`): single Markdown rule file, presence = `turn`.
  `gemini`, `antigravity` today; the natural home for **OpenCode (#136)** and
  **Cursor (#131)** — each becomes a 3-line `drivers/<type>.sh` + a path in
  `resolve_hooks_file`, no dispatcher edits.
- **json-hooks** (planned `_jsonhooks.sh`): JSON hook file. `claude-code`
  (settings.json, supports `monitor`/`both`), `codex`, `copilot`.
- **manual** (planned): no hook file, `off` only. **Hermes (#118/#119)** —
  already implemented as `apply_settings_manual_only` in that PR; would move
  here as `drivers/hermes.sh`.

## Adding a rule-file runtime (worked example: opencode)

```sh
# 1) resolve_hooks_file(): opencode) echo "$project/.opencode/rules/agmsg.md" ;;
# 2) scripts/drivers/opencode.sh:
agmsg_driver_apply()  { rulefile_apply "$@"; }
agmsg_driver_status() { rulefile_status "$@"; }
# 3) join.sh allowlist: add `opencode`
```

No edits to `apply_settings` / `do_status`.
