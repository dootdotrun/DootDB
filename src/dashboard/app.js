/* Doot dashboard client. Plain JavaScript, no framework, no bundler (05-architecture.md).
 *
 * No inline script anywhere: D89's CSP forbids 'unsafe-inline', so this file is the
 * only script the shell loads.
 *
 * Flow (D90, D91, D92, D93):
 *   1. GET /app/account: 200 is signed in, 401 is the sign-in screen. The response is
 *      also the whole bootstrap -- credits, plan limits, and the synchroniser token.
 *   2. Signed in with no keys: create one (D91). The plaintext lives in this variable
 *      and nowhere else -- not storage, not the URL (D76).
 *   3. GET /app/tags feeds the explorer. A current tag is re-listed on every live
 *      frame, coalesced to one in flight and one per 500 ms (D93).
 *   4. EventSource('/app/stream') first; after 20 s with no frame at all, close it and
 *      poll the same path as JSON for the rest of the page's life (D93).
 */

"use strict";

const state = {
  account: null,
  synchroniser: null,
  tags: [],
  currentTag: null,
  entries: [],
  liveMode: "connecting",
  issuedKey: null, // D91: the one moment the plaintext exists.
  pollCursor: null,
  refetchAt: 0,
  refetchInflight: false,
};

function el(id) {
  return document.getElementById(id);
}

function show(id) {
  for (const s of document.querySelectorAll("main > section")) s.hidden = true;
  el(id).hidden = false;
}

async function api(path, opts) {
  const r = await fetch(path, Object.assign({ credentials: "same-origin" }, opts));
  if (r.status === 401) {
    // A 401 after a successful bootstrap means the session ended underneath the
    // page (D90): back to sign-in rather than retrying.
    if (state.account !== null) {
      state.account = null;
      renderAuth();
    }
    return null;
  }
  return r;
}

function syncHeaders(extra) {
  return Object.assign({ "X-Doot-Synchroniser": state.synchroniser }, extra);
}

/* -- bootstrap (D90) -- */

async function bootstrap() {
  const r = await fetch("/app/account", { credentials: "same-origin" });
  if (r.status === 401) {
    renderAuth();
    return;
  }
  if (!r.ok) {
    renderFatal("Could not reach the account. Reload to try again.");
    return;
  }
  const body = await r.json();
  state.account = body;
  state.synchroniser = body.synchroniser;
  renderApp();
  await ensureFirstKey();
  await loadTags();
  watchLive();
}

function renderFatal(msg) {
  el("fatal-text").textContent = msg;
  show("view-fatal");
}

/* -- sign-in, signup, logout -- */

function renderAuth() {
  show("view-auth");
}

async function submitForm(path, formId, targetId) {
  const form = el(formId);
  const target = el(targetId);
  target.textContent = "";
  const r = await fetch(path, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(new FormData(form)),
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    target.textContent = body.error ? body.error.code : "request failed";
    target.className = "error";
    return null;
  }
  return body;
}

async function doSignup(ev) {
  ev.preventDefault();
  const body = await submitForm("/app/auth/signup", "signup-form", "signup-msg");
  if (body) el("signup-msg").textContent = "Check your mail for the six-digit code, then verify.";
}

async function doVerify(ev) {
  ev.preventDefault();
  const body = await submitForm("/app/auth/verify", "verify-form", "verify-msg");
  if (body) {
    state.synchroniser = body.synchroniser;
    await bootstrap();
  }
}

async function doLogin(ev) {
  ev.preventDefault();
  const body = await submitForm("/app/auth/login", "login-form", "login-msg");
  if (body) await bootstrap();
}

async function doLogout() {
  await fetch("/app/auth/logout", {
    method: "POST",
    credentials: "same-origin",
    headers: syncHeaders(),
  });
  state.account = null;
  renderAuth();
}

/* -- first-run key (D91) -- */

async function ensureFirstKey() {
  const r = await api("/app/keys");
  if (!r || !r.ok) return;
  const body = await r.json();
  if (body.keys.length === 0) {
    const created = await api("/app/keys", { method: "POST", headers: syncHeaders() });
    if (!created || !created.ok) return;
    const key = await created.json();
    // Shown once, kept in this variable, never stored (D76, D91).
    state.issuedKey = key.api_key;
    renderFirstRun(key.api_key);
  } else {
    renderKeys(body.keys);
  }
  refreshKeysPanel();
}

function renderFirstRun(plaintext) {
  el("first-key").textContent = plaintext;
  el("first-curl").textContent = curlFor(plaintext);
  el("first-run").hidden = false;
}

function dismissFirstRun() {
  // Correct rather than a gap (D91): the plaintext is gone, and the remedy is the
  // same rotation keys already use -- create another, up to five.
  state.issuedKey = null;
  el("first-run").hidden = true;
}

/* -- explorer (D92) -- */

async function loadTags() {
  const r = await api("/app/tags");
  if (!r || !r.ok) return;
  const body = await r.json();
  state.tags = body.tags.slice().sort();
  renderTags();
  if (state.currentTag === null && state.tags.length > 0) {
    state.currentTag = state.tags[0];
    await listEntries();
  }
  if (body.truncated) el("tags-note").textContent = "Showing a partial tag list.";
}

function renderTags() {
  const box = el("tag-list");
  box.textContent = "";
  for (const t of state.tags) {
    const b = document.createElement("button");
    b.textContent = t;
    b.className = "secondary";
    b.addEventListener("click", () => {
      state.currentTag = t;
      listEntries();
    });
    box.appendChild(b);
    box.appendChild(document.createTextNode(" "));
  }
}

async function listEntries() {
  if (state.currentTag === null) return;
  const r = await api("/app/entries?tag=" + encodeURIComponent(state.currentTag) + "&limit=100");
  if (!r || !r.ok) return;
  const body = await r.json();
  state.entries = body.entries;
  renderEntries();
}

function renderEntries() {
  const box = el("entry-list");
  box.textContent = "";
  el("current-tag").textContent = state.currentTag || "(pick a tag)";
  for (const e of state.entries) {
    const li = document.createElement("li");
    li.textContent = e.name + "  (" + e.size + " B, " + e.content_type + ")";
    li.addEventListener("click", () => readEntry(e.name));
    box.appendChild(li);
  }
  if (state.entries.length === 0) {
    const li = document.createElement("li");
    // An empty listing for a returned tag is ordinary: tags are known, not
    // non-empty (D92). Expiry reclaims entries; the name stays until a restart.
    li.textContent = "Nothing under this tag right now.";
    box.appendChild(li);
  }
}

async function readEntry(name) {
  const r = await api("/app/entries/" + name.split("/").map(encodeURIComponent).join("/"));
  if (!r || !r.ok) return;
  const ct = r.headers.get("Content-Type") || "application/octet-stream";
  const buf = await r.arrayBuffer();
  renderBody(ct, buf);
}

function renderBody(contentType, buf) {
  const box = el("entry-body");
  box.textContent = "";
  const pre = document.createElement("pre");
  pre.className = "curl";
  if (contentType.indexOf("application/json") !== -1) {
    try {
      pre.textContent = JSON.stringify(
        JSON.parse(new TextDecoder().decode(buf)), null, 2);
    } catch (e) {
      pre.textContent = "Invalid JSON (" + buf.byteLength + " bytes).";
    }
  } else if (contentType.indexOf("text/") === 0) {
    pre.textContent = new TextDecoder().decode(buf);
  } else {
    pre.textContent = contentType + ", " + buf.byteLength + " bytes.";
  }
  box.appendChild(pre);
}

/* -- keys panel -- */

async function refreshKeysPanel() {
  const r = await api("/app/keys");
  if (!r || !r.ok) return;
  renderKeys((await r.json()).keys);
}

function renderKeys(keys) {
  const box = el("key-list");
  box.textContent = "";
  for (const k of keys) {
    const li = document.createElement("li");
    li.textContent = k.id + "  " + k.created_at + "  ";
    const del = document.createElement("button");
    del.textContent = "revoke";
    del.className = "secondary";
    del.addEventListener("click", async () => {
      await api("/app/keys/" + k.id, { method: "DELETE", headers: syncHeaders() });
      refreshKeysPanel();
    });
    li.appendChild(del);
    box.appendChild(li);
  }
}

async function createKey() {
  const r = await api("/app/keys", { method: "POST", headers: syncHeaders() });
  if (!r) return;
  const body = await r.json().catch(() => ({}));
  if (!r.ok) {
    el("keys-msg").textContent = body.error ? body.error.code : "request failed";
    return;
  }
  state.issuedKey = body.api_key;
  renderFirstRun(body.api_key);
  refreshKeysPanel();
}

/* -- account panel (D90) -- */

function renderApp() {
  const a = state.account;
  el("account-email").textContent = a.email;
  el("account-id").textContent = a.account_id;
  el("credits-remaining").textContent = a.credits.remaining;
  el("plan-name").textContent = a.plan;
  el("credits-mail").href =
    "mailto:support@doot.run?subject=Credits%20for%20" + encodeURIComponent(a.account_id);
  show("view-app");
}

async function refreshCredits() {
  const r = await api("/app/account");
  if (!r || !r.ok) return;
  const body = await r.json();
  state.account = body;
  state.synchroniser = body.synchroniser;
  el("credits-remaining").textContent = body.credits.remaining;
}

/* -- the paste-ready command (D91) -- */

function curlFor(plaintext) {
  // From location.origin: the string pasted must name the host actually being
  // looked at, whether behind the edge, a preview, or localhost (D91).
  const tag = state.currentTag || "getting-started";
  return (
    "curl -X PUT " + window.location.origin + "/v1/entries/getting-started/hello \\\n" +
    '  -H "Authorization: Bearer ' + plaintext + '" \\\n' +
    '  -H "X-Doot-Tags: ' + tag + '" \\\n' +
    '  -H "X-Doot-TTL: 14d" \\\n' +
    '  --data-binary \'{"hello": "doot"}\''
  );
}

/* -- live view (D93) -- */

function setLiveMode(mode) {
  state.liveMode = mode;
  const badge = el("live-badge");
  badge.textContent = mode === "live" ? "live" : mode === "polling" ? "polling" : "connecting";
  badge.className = mode === "live" ? "status-live" : "status-polling";
}

function watchLive() {
  setLiveMode("connecting");
  const src = new EventSource("/app/stream");
  // Satisfied by anything at all -- an event frame or a heartbeat comment. The
  // heartbeat is due at 15 s, so a working stream must produce something inside
  // 20 s, while a buffering path produces nothing (D93).
  const deadline = window.setTimeout(() => {
    // Sticky for the page's lifetime: a path that buffered once will buffer again
    // (D93).
    src.close();
    setLiveMode("polling");
    pollLoop();
  }, 20000);

  src.onmessage = (ev) => {
    window.clearTimeout(deadline);
    setLiveMode("live");
    onFrame();
  };
  src.addEventListener("resync", () => {
    window.clearTimeout(deadline);
    setLiveMode("live");
    onFrame();
  });
  src.onerror = () => {
    // A dead stream without a frame is the same as a buffered one: fall back.
    // (A stream that errored after frames arrived keeps its EventSource; only the
    // first-frame deadline switches transports.)
  };
}

function onFrame() {
  // A frame is a notification, so the response is to re-run the current listing --
  // coalesced to one in flight and one per 500 ms, because the control-plane bucket
  // is 300 ops/min and an uncoalesced refetch rate-limits the dashboard out of its
  // own live view (D93).
  const now = Date.now();
  if (state.refetchInflight || now < state.refetchAt) return;
  state.refetchInflight = true;
  state.refetchAt = now + 500;
  Promise.all([listEntries(), refreshCredits()]).finally(() => {
    state.refetchInflight = false;
  });
}

async function pollLoop() {
  for (;;) {
    const q = state.pollCursor === null ? "" : "?cursor=" + state.pollCursor;
    const r = await fetch("/app/stream" + q, {
      credentials: "same-origin",
      headers: { Accept: "application/json" },
    });
    if (r.status === 401) {
      if (state.account !== null) {
        state.account = null;
        renderAuth();
      }
      return;
    }
    if (r.ok) {
      const body = await r.json();
      state.pollCursor = body.cursor;
      if (body.events.length > 0 || body.resync) onFrame();
    }
    await new Promise((done) => window.setTimeout(done, 3000));
  }
}

window.addEventListener("DOMContentLoaded", () => {
  el("signup-form").addEventListener("submit", doSignup);
  el("verify-form").addEventListener("submit", doVerify);
  el("login-form").addEventListener("submit", doLogin);
  el("logout-btn").addEventListener("click", doLogout);
  el("dismiss-key").addEventListener("click", dismissFirstRun);
  el("create-key").addEventListener("click", createKey);
  bootstrap();
});
