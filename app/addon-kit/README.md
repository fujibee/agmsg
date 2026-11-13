# agmsg add-on kit

The one file an add-on needs to talk to the app is `agmsg-addon.js`: copy it into your add-on's `web/` folder and `import { connect } from "./agmsg-addon.js"`. `protocol.d.ts` types everything below. `PORTING-PROMPT.md` is the longer guide (permissions, layout, checks) to hand to a coding agent.

What the app tells your add-on arrives as events on the options of `connect`, or as properties on the object it returns. Each one is optional: leave it out and the add-on works as before, and an older app that does not send it leaves the matching flag false.

```js
import { connect, pickLocale } from "./agmsg-addon.js";

const app = connect({
  onInit({ team, members, messages }) {},   // once the frame is ready: the team, its members and recent messages
  onMessage(message) {},                    // each new message in the team (needs messages:read)
  onNotice({ name, at, ids }) {},           // a notice was typed into an agent this add-on started
  onStatus({ name, state, at }) {},         // an agent pane in the team changed state, or closed
});
```

## Locale

`app.locale` is the app's language tag (`"en"` until it has said otherwise). `await app.localeReady` resolves with it before first paint, and `app.onLocaleChange((tag) => …)` fires when the user changes the language. Load your own strings with a relative `fetch` and pick the file with `pickLocale(app.locale, ["en", "ja"])`.

## Notices (delivery)

An add-on that starts an agent and sends it a message can learn when the app typed the notice into the agent's terminal: `onNotice({ name, at, ids })`, where `ids` are the ids of the messages the notice was about (match them against the messages you sent). Use it to start a clock when the agent actually got the message. `app.canReportDelivery` is true once the app says it reports these. Needs `agents:spawn` for the agent's team.

## Status

An add-on that reads a team (`messages:read`) can ask which agents are open and what they are doing. No other permission is needed.

```js
const { agents } = await app.agents.status();  // [{ name, type, state, since }]
```

- `state` is `idle`, `working`, `blocked` or `unknown`; `since` is when it entered that state (ms since epoch).
- `onStatus({ name, state, at })` is called when an agent pane's state changes, and once with `state: "closed"` when the pane goes away. A pane that opens is reported as `unknown` (the app's own state until it has read the pane), then as it changes. A pane whose agent process has ended is `closed`, even if its tab stays open.
- `app.canReportStatus` is true once the app says it reports these. With an older app it stays false: show nothing, or use your own signal.
- Only agent panes are listed, by member name. Shells, add-on panes and members with no open pane are not. No pane id, command, folder or terminal text is sent.
- `agents.status()` is refused with `not_granted` once `messages:read` is revoked, and the events stop.

Tests of the kit itself run with `pnpm exec vitest run addon-kit`.
