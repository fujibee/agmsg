# plugins/

Drop external **drivers** here to extend agmsg without forking it. This is the
default plugin search base (`<skill>/plugins/`); `$AGMSG_PLUGIN_DIRS` can add more.

Layout mirrors the built-ins under `scripts/drivers/` — one directory per driver,
grouped by axis:

```
plugins/
└── <axis>/            # types | storage | delivery
    └── <name>/        # e.g. plugins/types/foo/
        └── …          # same layout as a built-in driver of that axis
```

For the `types` axis, a plugin is exactly a built-in agent type placed here (a
`type.conf` manifest + `template.md`, plus an optional `_delivery.sh`). See
[../docs/agent-types.md](../docs/agent-types.md).

**Trust is required.** A driver is shell code that runs with your privileges, so
anything dropped here is **ignored until you opt in**:

```
agmsg plugin list                 # shows it as UNTRUSTED
agmsg plugin trust types/foo      # opt in (path-pinned)
```

Full details: [../docs/plugins.md](../docs/plugins.md) ·
rationale: [../docs/adr/0002-driver-discovery-and-plugin-opt-in.md](../docs/adr/0002-driver-discovery-and-plugin-opt-in.md)

`plugins/sources/` is reserved: `agmsg plugin install <owner>/<repo>` keeps its
checkouts there (one directory per commit) and records them in
`db/plugin-sources`. Do not put hand-made plugins in it, and do not edit it by hand;
use `agmsg plugin update` / `remove`.

> This directory ships with only this README. Your trusted plugins and the
> `db/trusted-plugins` allowlist are preserved across `--update` installs.
