# Remote setup

This walkthrough runs the reference server on localhost and syncs one plaintext
team between two isolated agmsg installs. It does not change an existing agmsg
install.

## Requirements

- Docker with Docker Compose
- Bash, SQLite, and curl
- Node.js 22 or later
- A local checkout of this repository

Run every command below from the repository root unless the step says
otherwise.

## 1. Start the reference server

Use a dedicated Compose project so this walkthrough does not reuse another
local server's database:

```sh
export COMPOSE_PROJECT_NAME=agmsg-remote-setup
docker compose -f server/compose.yaml up -d --build
curl -fsS http://127.0.0.1:8787/v1/health
```

The health response should contain `"status":"ok"` and `"database":"ok"`.

## 2. Install two isolated commands

Pick command names that are not used by an existing install. The names below
create separate skill, team, and message-store directories:

```sh
bash install.sh --cmd agmsg-remote-a --agent-type claude-code
bash install.sh --cmd agmsg-remote-b --agent-type claude-code
```

Set short path variables for the remaining commands:

```sh
A="$HOME/.agents/skills/agmsg-remote-a/scripts"
B="$HOME/.agents/skills/agmsg-remote-b/scripts"
```

## 3. Create a team on install A

Create two temporary project directories, then register two members in a new
local team:

```sh
DEMO_ROOT="$(mktemp -d)"
mkdir -p "$DEMO_ROOT/alice" "$DEMO_ROOT/bob"

bash "$A/join.sh" remote-demo alice claude-code "$DEMO_ROOT/alice"
bash "$A/join.sh" remote-demo bob claude-code "$DEMO_ROOT/bob"
```

## 4. Connect install A

Connect the local team to the reference server:

```sh
bash "$A/remote.sh" connect \
  --endpoint http://127.0.0.1:8787 \
  remote-demo
```

The command registers the team, moves its local history into the team's
dedicated store, and starts its sync engine.

## 5. Pull the team into install B

Install B starts without a local `remote-demo` team. Pull it by name:

```sh
bash "$B/remote.sh" pull \
  --endpoint http://127.0.0.1:8787 \
  remote-demo
```

The command creates the local team, imports its current history, and starts a
second sync engine.

## 6. Send and verify

Send a message from install A:

```sh
bash "$A/send.sh" remote-demo alice bob "hello from install A"
```

Run one cycle on each side to make the walkthrough deterministic, then inspect
install B's local history:

```sh
bash "$A/remote-sync.sh" once --team remote-demo
bash "$B/remote-sync.sh" once --team remote-demo
bash "$B/history.sh" remote-demo bob
```

The final command should show:

```text
alice → bob: hello from install A
```

## Stop the server

Use the same Compose project name from step 1:

```sh
docker compose -f server/compose.yaml down
```
