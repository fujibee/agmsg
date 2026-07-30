# Remote setup

This walkthrough connects an existing team on machine A to the reference
server, then pulls it into a normal agmsg install on machine B. This setup uses
plaintext sync.

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

Use machine A's normal agmsg install and the team you already use:

```sh
bash ~/.agents/skills/agmsg/scripts/remote.sh connect \
  --endpoint https://<server-url> \
  <team>
```

Connect moves this team from the shared database into a per-team store. If an
external tool reads the database file directly, resolve the team's new path
instead of continuing to use the shared database path:

```sh
bash ~/.agents/skills/agmsg/scripts/api.sh get teams <team> store
```

## 3. Install and pull on machine B

Install agmsg normally on machine B:

```sh
npx agmsg
```

Pull the connected team by name:

```sh
bash ~/.agents/skills/agmsg/scripts/remote.sh pull \
  --endpoint https://<server-url> \
  <team>
```

## 4. Send and verify

Send a message from machine A with member names from the team:

```sh
bash ~/.agents/skills/agmsg/scripts/send.sh \
  <team> <from> <to> "hello from machine A"
```

Connect and pull already started the sync engines. Wait a few seconds, then
inspect machine B's local history:

```sh
bash ~/.agents/skills/agmsg/scripts/history.sh <team> <to>
```

The history should contain:

```text
<from> → <to>: hello from machine A
```

## Use a separate install for testing

To keep a test separate from an existing install, clone the repository and run
this from the checkout root:

```sh
bash install.sh --cmd agmsg-test
```

That install's commands are under `~/.agents/skills/agmsg-test/scripts/`.

For the single-machine, two-install rehearsal, see
[Try it on one machine](design/remote-sync.md#try-it-on-one-machine).

## Back up before connecting

If you want a rollback copy, do this before step 2:

Here `<storage>` is the install root, normally `~/.agents/skills/agmsg`.

1. Back up `<storage>/db/messages.db` and the entire `<storage>/teams/` directory.
2. To restore, run `bash <storage>/scripts/delivery.sh stop`, then
   `bash <storage>/scripts/remote.sh disconnect <team>`.
3. Copy both backups back to their original paths.
4. Delete `<storage>/db/teams/<team>/`, then restart your normal delivery mode.
