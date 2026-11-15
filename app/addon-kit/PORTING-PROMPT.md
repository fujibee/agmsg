# Porting prompt: turn a web app into an agmsg app add-on

Hand this whole file to your coding agent (Claude Code, Codex, …) from the root of your project, for example: "Follow PORTING-PROMPT.md to make this project an agmsg app add-on."

---

You are turning the web app in this repository into an **agmsg app add-on**: a pane in the agmsg desktop app that receives a team's messages (and, if declared, can read files or git history in a folder the user picks). Work in this repository only. Do not install anything globally and do not touch `~/.agents`.

## What an add-on is

```
<repo>/
  agmsg-plugin.conf              # name, description
  app-panes/<name>/
    addon.conf                   # key=value, data only
    web/                         # the BUILT app, committed; entry web/index.html
```

The app serves `web/` to a sandboxed iframe with an opaque origin and this CSP (`<own>` is the pane's own origin):

```
default-src <own>; script-src <own> <hashes of inline scripts>; style-src <own> 'unsafe-inline';
img-src <own> <net> data: blob:; font-src <own> <net> data:; media-src <own> <net> blob:;
connect-src <own> <net>; frame-src 'none'; worker-src <own>; form-action 'none'; base-uri 'none'
```

`<net>` is empty unless `addon.conf` declares `network`. That means, at run time:
- No CDN scripts or fonts unless declared; prefer bundling them.
- No `eval`, `new Function`, inline event-handler attributes (`onclick="…"`), WebAssembly, or `blob:` workers. Code runs only from files in `web/`.
- `localStorage`/`sessionStorage`/IndexedDB throw. Settings last only while the pane is open.
- The frame cannot navigate to another page, open popups, or submit forms.
- `fetch()` of your own files in `web/` works (use relative URLs).

## Steps

1. **Read the project.** Find the framework, the build command, the output directory, and where the app gets its data today (file import, an API, a dev-server endpoint).

2. **Make the build relative.** For Vite set `base: "./"`; for other bundlers the equivalent (`publicPath: "./"`, `assetPrefix: "./"`). Replace absolute asset paths in code (`"/assets/…"`, `src="/…"`) with relative ones (`"./assets/…"`) or `import.meta.env.BASE_URL`.

3. **Add the helper.** Copy `kit/agmsg-addon.js` from the sample add-on (https://github.com/fujibee/agmsg-addon-sample) into the source tree, and connect where the app loads its data:

   ```js
   import { connect } from "./agmsg-addon.js";
   connect({
     onInit({ team, members, messages }) { /* replace the initial data load */ },
     onMessage(message) { /* append one new message */ },
   });
   ```

   `Message` is `{ id: string, team, from, to, body, created_at }` (ISO time; order by array position or `created_at`). Map it to the app's own shape in one small function. Worked example (agmsg-office reads agmsg's database rows): `{ id, team, from_agent: m.from, to_agent: m.to, body: m.body, created_at: m.created_at }`.

   Outside the app (your dev server in a normal browser) the helper serves sample data after one second, so the app still renders during development. Keep the old data source only if it still makes sense outside the app; it must not be needed inside it.

4. **Declare exactly the permissions the code uses** in `app-panes/<name>/addon.conf`:

   ```
   title = My Viewer
   entry = index.html
   min_app = 0.6.0          # example: use the first app version with add-ons (see the author guide)
   protocol = 1
   permissions = messages:read
   why.messages:read = Shows the conversation as a timeline.
   ```

   Available: `messages:read`; `files:read` (a folder the user picks; `app.fs.list/stat/read`); `git:read` (with `files:read`; `app.git.*`); `network` with `network = https://api.example.com` (or `*`). Add `opens = path` or `opens = url` if the add-on is opened with one. Write one honest `why.<permission>` line for each; users see it. Never declare a permission the code does not use.

5. **Remove what the sandbox blocks.** Inline handlers → `addEventListener`. Runtime code generation → plain code. Remote scripts/fonts → bundled, or declared under `network` (fonts and images only; scripts never load from the network). Storage → wrap every access in `try/catch` and keep working without it.

6. **Build and copy.** Run the project's build, then copy the output into `app-panes/<name>/web/` (copy the sample's `kit/agmsg-addon-copy.mjs` to `scripts/` and run `node scripts/agmsg-addon-copy.mjs <build-dir> <name>`). Commit `web/` — the app installs exactly what is committed.

7. **Check.** Copy the sample's `kit/agmsg-addon-check.cjs` to `scripts/`, run `node scripts/agmsg-addon-check.cjs`, and fix everything it reports until it is clean. It checks the repository the way the app checks an install.

8. **Tell the author how to see it:** in the agmsg app, Settings → Add-ons → Developer → **Load from folder…**, pick this repository, and open the pane from **＋ New ▾ → Add-on pane**.

## Localizing the add-on (optional)

The app tells every add-on its language, so an add-on can follow the app. Nothing is required: an add-on that ignores it works as before.

- `app.locale` is the app's language tag (`en`, `ja`, `zh-CN`, `zh-TW`, `ko`, `es`, `fr`, `de` or `pt-BR`); it is `en` until the app has said otherwise. `await app.localeReady` resolves with it before first paint (with `en` after about a second when no app answers, so it never hangs). `app.onLocaleChange((tag) => …)` fires when the user changes the language, and returns a function that stops it.
- Ship your own strings as `web/locales/<tag>.json` and load them yourself with a relative `fetch("./locales/ja.json")`. The app has no file call for this and needs none. Pick the file with `pickLocale(app.locale, ["en", "ja"])`: an exact match, then the language alone (`pt-BR` finds `pt`), then `en`. An add-on that has no file for the app's language simply shows its default; nothing is reported to the user.

  ```js
  import { connect, pickLocale } from "./agmsg-addon.js";
  const SUPPORTED = ["en", "ja"];
  const app = connect({ /* … */ });
  let strings = {};
  let latest = 0;
  async function load(tag) {
    const n = ++latest;
    const res = await fetch(`./locales/${pickLocale(tag, SUPPORTED)}.json`);
    const next = await res.json();
    if (n === latest) { strings = next; render(); }   // ignore an answer the user already moved past
  }
  load(await app.localeReady);
  app.onLocaleChange(load);
  ```

- In `addon.conf`, `locales = en, ja` lists the tags you ship and `default = en` names the one used when none matches (`en` if omitted). Both are optional and advisory: the app never refuses an add-on over them, and an add-on works the same without them. `agmsg-addon-check` warns (never errors) when a tag is not shaped like a language tag or is repeated, when a listed `web/locales/<tag>.json` is missing, or when `default` is not listed; the app ignores a bad entry the same way and still installs the add-on.
- Only the tag is sent. It costs no process and one small message per open pane per language change.

## Showing what the agents are doing (optional)

An add-on that reads a team's messages (`messages:read`) can also see which agents are open in that team and what each is doing. It needs no other permission, and an add-on that ignores it works as before.

- `await app.agents.status()` returns `{ agents: [{ name, type, state, since }] }`: the agent panes open now in the granted team. `state` is `idle`, `working`, `blocked` or `unknown` (the app's own words), `since` is when it entered that state (ms since epoch). A member with no open pane is not listed.
- `onStatus({ name, state, at })` in `connect({...})` is called when an agent pane changes state, and with `state: "closed"` when it goes away. A pane that opens is reported with its first state. It is called only on a change, never on a timer.
- `app.canReportStatus` is true once the app has said it reports these; an older app leaves it false, so show nothing or fall back to your own signal. `agents.status()` is refused as `not_granted` once `messages:read` is revoked.
- No pane id, command, folder or terminal text is ever sent. It costs no process and one small message per open pane per change.

## Do not

- Do not add `allow-same-origin`, iframes of other sites, or any other workaround for the sandbox; they will not work and the app refuses them.
- Do not declare permissions the code does not use.
- Do not remove or alter license notices or third-party credits. If the app bundles art or fonts with their own terms, keep their notices in `web/` and tell the author to check that redistribution is allowed.
- Do not commit secrets, `.env` files, or local data into `web/`.
