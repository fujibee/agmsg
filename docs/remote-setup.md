# Remote setup

This walkthrough connects an existing team on machine A to the reference
server, then pulls it into a normal agmsg install on machine B. Your local
agents handle the client commands. This setup uses plaintext sync.

## Requirements

- PostgreSQL 17
- Node.js 22 or later
- Bash, SQLite, and curl
- An agmsg checkout on the server host
- A server URL that both machines can reach

Use HTTPS when the server is not on localhost.

## 1. Start the reference server

Create an empty PostgreSQL database, then start the server from the repository
checkout:

```sh
cd server
npm ci

export DATABASE_URL="postgresql://<user>:<password>@127.0.0.1:5432/<db>"
export HOST=0.0.0.0
export PORT=8787
npx tsx src/index.ts
```

Replace every value in angle brackets, especially `<db>`, with the real
PostgreSQL values before running the command. The example will not work until
you replace them.

Make the server available to both machines at an HTTPS URL, then confirm it is
ready:

```sh
curl -fsS https://<server-url>/v1/health
```

The response should contain `"status":"ok"` and `"database":"ok"`.

## 2. Connect the existing team on machine A

Open your usual local agent on machine A and ask:

> Connect my existing agmsg team `<team>` to `https://<server-url>`.

The agent will connect the local team and report the result. It will finish by
showing a copy-paste `remote.sh pull` command with your server URL and team
name already filled in.

Connect moves this team from the shared database into a per-team store. If an
external tool reads the database file directly, resolve the team's new path
instead of continuing to use the shared database path. Ask the agent for the
team's store path, or use the command in [Reference](#reference).

## 3. Install and pull on machine B

Install agmsg normally on machine B, then paste the `remote.sh pull` command
that machine A's agent displayed. Do not create a same-named local team first;
pull imports the team that already exists on the server.

After pull succeeds, the team is local and works like any other local team.
Open your agent, invoke its installed `agmsg` command, and join the team with a
new agent name.

## 4. Send and verify

On machine A, ask your local agent:

> Send `hello from machine A` from `<from>` to `<to>` in team `<team>`.

Connect and pull already started the sync engines. Wait a few seconds, then
use the [history command](#client-commands-send-and-verify) on machine B.

The history should contain:

```text
<from> → <to>: hello from machine A
```

## Reference

### Install on machine B

Use the standard installation entry point:

```sh
npx agmsg
```

### Connect machine A

```sh
bash ~/.agents/skills/agmsg/scripts/remote.sh connect \
  --endpoint https://<server-url> \
  <team>
```

### Resolve the team store

```sh
bash ~/.agents/skills/agmsg/scripts/api.sh get teams <team> store
```

### Pull on machine B

```sh
bash ~/.agents/skills/agmsg/scripts/remote.sh pull \
  --endpoint https://<server-url> \
  <team>
```

### Client commands: send and verify

```sh
bash ~/.agents/skills/agmsg/scripts/send.sh \
  <team> <from> <to> "hello from machine A"

bash ~/.agents/skills/agmsg/scripts/history.sh <team> <to>
```

### Use a separate install for testing

To keep a test separate from an existing install, clone the repository and run
this from the checkout root:

```sh
bash install.sh --cmd agmsg-test
```

That install's commands are under `~/.agents/skills/agmsg-test/scripts/`.

For the single-machine, two-install rehearsal, see
[Try it on one machine](design/remote-sync.md#try-it-on-one-machine).

### Back up before connecting

If you want a rollback copy, do this before step 2:

Here `<storage>` is the install root, normally `~/.agents/skills/agmsg`.

1. Back up `<storage>/db/messages.db` and the entire `<storage>/teams/` directory.
2. To restore, run `bash <storage>/scripts/delivery.sh stop`, then
   `bash <storage>/scripts/remote.sh disconnect <team>`.
3. Copy both backups back to their original paths.
4. Delete `<storage>/db/teams/<team>/`, then restart your normal delivery mode.
