// The approval page: server-rendered HTML with no script. Every value that
// reaches it is escaped; the page is sent with a CSP that allows nothing else.

export const PAGE_HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "referrer-policy": "no-referrer",
  "x-frame-options": "DENY",
  "content-security-policy":
    "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'",
} as const;

export function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/gu, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] ?? c);
}

function layout(title: string, body: string): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8">` +
    `<meta name="viewport" content="width=device-width, initial-scale=1">` +
    `<title>${escapeHtml(title)}</title><style>` +
    `body{font:16px/1.5 system-ui,sans-serif;max-width:32rem;margin:3rem auto;padding:0 1rem}` +
    `input,select,button{font:inherit;padding:.5rem;margin:.25rem 0;width:100%;box-sizing:border-box}` +
    `button{cursor:pointer}.row{display:flex;gap:.5rem}.row button{flex:1}` +
    `code{background:#eee;padding:.1rem .3rem}.err{color:#b00020}` +
    `</style></head><body>${body}</body></html>`;
}

export function signInPage(userCode: string, failed: boolean): string {
  return layout("Sign in", `<h1>Sign in</h1>` +
    (failed ? `<p class="err">That secret is not right.</p>` : "") +
    `<form method="post" action="/approve/signin">` +
    `<input type="hidden" name="user_code" value="${escapeHtml(userCode)}">` +
    `<label>Owner secret<input type="password" name="secret" autocomplete="off" required></label>` +
    `<button type="submit">Sign in</button></form>`);
}

export function codeEntryPage(message: string | null): string {
  return layout("Approve a device", `<h1>Approve a device</h1>` +
    (message ? `<p class="err">${escapeHtml(message)}</p>` : "") +
    `<form method="get" action="/approve">` +
    `<label>Code shown on the device<input name="user_code" autocomplete="off" required></label>` +
    `<button type="submit">Continue</button></form>`);
}

export function decisionPage(input: {
  userCode: string;
  clientId: string;
  machineName: string;
  teamId: string | null;
  teams: Array<{ teamId: string; teamName: string }>;
}): string {
  const team = input.teamId !== null
    ? `<p>Team: <code>${escapeHtml(input.teamId)}</code></p>` +
      `<input type="hidden" name="team_id" value="${escapeHtml(input.teamId)}">`
    : `<label>Team<select name="team_id" required>` +
      input.teams.map((t) =>
        `<option value="${escapeHtml(t.teamId)}">${escapeHtml(t.teamName)} (${escapeHtml(t.teamId)})</option>`,
      ).join("") + `</select></label>`;
  return layout("Approve a device", `<h1>Approve this device?</h1>` +
    // Both values are what the device says about itself, not verified facts.
    `<p>A machine calling itself <strong>${escapeHtml(input.machineName)}</strong> ` +
    `(client <code>${escapeHtml(input.clientId)}</code>) asks to read and write messages. ` +
    `Approve only if you just started this on your own machine.</p>` +
    `<form method="post" action="/approve/decision">` +
    `<input type="hidden" name="user_code" value="${escapeHtml(input.userCode)}">${team}` +
    `<div class="row"><button name="decision" value="approve">Approve</button>` +
    `<button name="decision" value="deny">Deny</button></div></form>`);
}

export function messagePage(title: string, text: string): string {
  return layout(title, `<h1>${escapeHtml(title)}</h1><p>${escapeHtml(text)}</p>`);
}
