#!/usr/bin/env python3
"""Aggregate every locally known team's config.json into the strict
`agmsg team list --json` ABI (ADR 0007 family addition). See
scripts/team-list.sh's own header comment for the full field contract.

Reads two small input files by path (never a huge argv, since a
pathological team count/project-path could otherwise blow past ARG_MAX):
  --entries <path>   TAB-separated "<name>\t<config_path>" lines, one per
                      locally known team directory (already existence-
                      checked and bounded by the caller).
  --variants <path>  one project-path spelling per line (from
                      agmsg_project_path_variants) — a team is "project"-
                      scoped if ANY agent registration's `project` field
                      exactly matches ANY of these.

Each config.json is read up to --max-config-bytes+1 bytes and rejected
(skipped, with a stderr warning naming the team) if it exceeds that
bound, isn't valid UTF-8 JSON, isn't a JSON object, or contains a
duplicate key at any nesting depth (the same #87/D4-class strict-parsing
discipline this ADR family already applies to server-supplied JSON —
config.json is locally written by our own scripts, but this is a
read-only listing command with no reason to guess at a malformed file's
meaning rather than skip it outright).

Fail-closed in --format json specifically (delta review): --scope all
is the authority a no-arg cloud connect flow uses to decide whether its
choice is ambiguous (one team vs several). Silently returning a partial
list as if it were the complete one — because one team's config failed
to parse, or the caller's own MAX_TEAMS bound was hit — could make a
driver see "1 team" or "0 teams" and auto-select/report ambiguity
wrongly, when the true count differs. So in JSON mode, if ANY team was
skipped or the entries list was truncated upstream (--truncated), this
prints NO JSON payload at all and exits 2, rather than a "successful"
partial object a consumer could mistake for authoritative. Human mode
(--format human) keeps printing whatever was found plus the warnings and
exits 0 — a person reading it isn't fooled by partial output the way an
automated ambiguity check would be, and seeing what's readable is more
useful to them than a bare error.
"""
import argparse
import json
import sys


_SKIPPED = 0


def _warn_skip(name, reason):
    global _SKIPPED
    _SKIPPED += 1
    print(f"agmsg: team list: skipping '{name}': {reason}", file=sys.stderr)


def _no_duplicate_keys(pairs):
    seen = set()
    out = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError(f"duplicate key '{key}'")
        seen.add(key)
        out[key] = value
    return out


def _strict_loads(raw):
    return json.loads(raw, object_pairs_hook=_no_duplicate_keys)


def _registrations_for(agent_value):
    regs = agent_value.get("registrations")
    if isinstance(regs, list):
        return regs
    # Legacy single-registration shape (type/project directly on the agent
    # object, no "registrations" array) — join.sh normalizes to the array
    # form on write, but an older config on disk may still be in this shape.
    return [{"type": agent_value.get("type"), "project": agent_value.get("project")}]


def _team_row(name, cfg, variants):
    binding = cfg.get("remote_binding")
    if not isinstance(binding, dict):
        binding = {}
    connected_at = binding.get("connected_at")
    disconnected_at = binding.get("disconnected_at")
    if not connected_at:
        binding_state = "none"
    elif disconnected_at:
        binding_state = "disconnected"
    else:
        binding_state = "active"

    # Named remote_team_id, not team_id: this is the
    # server-assigned id of the remote BINDING, not a stable local identity
    # anchor for the team itself — those are two different things, and a
    # team with no remote binding correctly has none of this at all. ADR
    # 0010 may define a local, always-present team identity later; that
    # would be a genuinely new field (e.g. local_team_id), not a
    # reinterpretation of this one.
    remote_team_id = binding.get("remote_team_id") if binding_state != "none" else None
    if not isinstance(remote_team_id, str) or not remote_team_id:
        remote_team_id = None

    scope = "other"
    agents = cfg.get("agents")
    if isinstance(agents, dict):
        for agent_value in agents.values():
            if not isinstance(agent_value, dict):
                continue
            for reg in _registrations_for(agent_value):
                if isinstance(reg, dict) and reg.get("project") in variants:
                    scope = "project"
                    break
            if scope == "project":
                break

    # onboarding_state/promote_eligible/blocked_reason are deliberately NOT
    # included in v1: their real meaning depends on ADR
    # 0010 (local-first onboarding / roster convergence), which hasn't
    # landed, so today they could only be a fixed/mechanically-derived
    # placeholder value — zero information a consumer couldn't already get
    # from binding_state, but a shipped field a consumer might still start
    # depending on. A shipped field whose MEANING later changes is a
    # breaking change; a field added later that didn't exist before is not.
    # So: add these additively, with real semantics, once ADR 0010 fixes
    # what they mean — never ship them as placeholders now.

    return {
        "name": name,
        "remote_team_id": remote_team_id,
        "scope": scope,
        "binding_state": binding_state,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--entries", required=True)
    parser.add_argument("--variants", required=True)
    parser.add_argument("--scope", required=True, choices=("all", "project"))
    parser.add_argument("--max-config-bytes", required=True, type=int)
    parser.add_argument("--format", required=True, choices=("human", "json"))
    parser.add_argument("--truncated", action="store_true",
                         help="the caller's own team-count bound was hit; "
                              "the entries file is itself incomplete")
    args = parser.parse_args()

    with open(args.variants, encoding="utf-8") as f:
        variants = {line.rstrip("\n") for line in f if line.rstrip("\n")}

    rows = []
    with open(args.entries, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            name, _, cfg_path = line.partition("\t")
            if not cfg_path:
                continue
            try:
                with open(cfg_path, "rb") as cf:
                    raw = cf.read(args.max_config_bytes + 1)
            except OSError as exc:
                _warn_skip(name, f"could not read config ({exc.__class__.__name__})")
                continue
            if len(raw) > args.max_config_bytes:
                _warn_skip(name, "config exceeds the byte limit")
                continue
            try:
                cfg = _strict_loads(raw.decode("utf-8"))
            except Exception as exc:
                _warn_skip(name, f"invalid config ({exc})")
                continue
            if not isinstance(cfg, dict):
                _warn_skip(name, "config is not a JSON object")
                continue
            rows.append(_team_row(name, cfg, variants))

    if args.scope == "project":
        rows = [r for r in rows if r["scope"] == "project"]

    # Canonical sort (name, then remote_team_id — null-safe via "").
    rows.sort(key=lambda r: (r["name"], r["remote_team_id"] or ""))

    incomplete = _SKIPPED > 0 or args.truncated

    if args.format == "json":
        if incomplete:
            reasons = []
            if args.truncated:
                reasons.append("the team count was truncated at the caller's bound")
            if _SKIPPED:
                reasons.append(f"{_SKIPPED} team config(s) were skipped as unreadable/invalid")
            print(
                "agmsg: team list --json: refusing to print a partial list as if it were "
                "complete (" + "; ".join(reasons) + "). Not safe to use as the --scope all "
                "ambiguity authority. See stderr above for which team(s) were skipped.",
                file=sys.stderr,
            )
            return 2
        sys.stdout.write(json.dumps({"schema_version": 1, "teams": rows}, sort_keys=True) + "\n")
    else:
        if not rows:
            print("No teams found.")
        else:
            for r in rows:
                remote_team_id_disp = r["remote_team_id"] or "-"
                print(f"{r['name']}\t{remote_team_id_disp}\t{r['scope']}\t{r['binding_state']}")
        if incomplete:
            print(
                "agmsg: warning: this list is incomplete (some teams were skipped or "
                "truncated — see warnings above).",
                file=sys.stderr,
            )

    return 0


if __name__ == "__main__":
    sys.exit(main())
