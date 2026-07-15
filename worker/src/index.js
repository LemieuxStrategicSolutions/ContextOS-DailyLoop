/**
 * Daily Loop — surface Worker
 *
 * Reads daily/YYYY-MM-DD.md from your PRIVATE context repo and renders it as a clean,
 * mobile-first HTML page. Today by default, with yesterday/tomorrow + date-jump nav.
 * Same repo-read/auth/cache pattern as the widget Worker (../../widget/worker/src/index.js).
 *
 * Privacy: the repo is private. The GitHub token lives ONLY as a Worker secret. The page is
 * gated by a shared secret (?key=...). No key, no page. Free-tier Worker.
 *
 * Required secrets (set via `wrangler secret put`):
 *   GITHUB_TOKEN  — fine-grained PAT, read-only "Contents" on YOUR private repo only
 *   DAILY_KEY     — long random string sent as ?key= (and remembered via cookie after first load)
 *
 * Required vars (wrangler.toml [vars]):
 *   GITHUB_REPO   — "your-github-user/your-context-repo"
 *   GITHUB_BRANCH — default "main"
 *   DAILY_DIR     — default "daily"
 *   TZNAME        — your IANA timezone
 */

const DEFAULTS = {
  GITHUB_REPO: "your-github-user/your-context-repo", // override in wrangler.toml [vars]
  GITHUB_BRANCH: "main",
  DAILY_DIR: "daily",
  TZNAME: "UTC",
};

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === "/" || url.pathname === "") {
      return html(landing(), 200);
    }
    if (url.pathname !== "/daily") {
      return html(`<p>not found</p>`, 404);
    }

    const cfg = { ...DEFAULTS, ...pickVars(env) };

    // --- auth gate: ?key= or the cookie we set on first valid load ---------
    const key = url.searchParams.get("key") || cookie(request, "dk");
    if (!env.DAILY_KEY || !key || !timingSafeEqual(key, env.DAILY_KEY)) {
      return html(`<h1>unauthorized</h1><p>append <code>?key=…</code></p>`, 401);
    }
    if (!env.GITHUB_TOKEN) {
      return html(`<h1>not configured</h1><p>missing GITHUB_TOKEN secret</p>`, 500);
    }

    const today = todayIn(cfg.TZNAME);
    const date = normalizeDate(url.searchParams.get("date")) || today;
    const path = `${cfg.DAILY_DIR}/${date}.md`;

    // short edge cache so home-screen taps don't hammer GitHub
    const cache = caches.default;
    const cacheKey = new Request(`${url.origin}/daily?date=${date}`, request);
    if (!url.searchParams.has("fresh")) {
      const hit = await cache.match(cacheKey);
      if (hit) return withCookie(hit, key);
    }

    let body, found = true;
    try {
      body = await ghRaw(cfg.GITHUB_REPO, path, cfg.GITHUB_BRANCH, env.GITHUB_TOKEN);
    } catch (err) {
      if (String(err.message).includes("404")) { found = false; body = ""; }
      else return html(`<h1>upstream error</h1><pre>${esc(String(err.message))}</pre>`, 502);
    }

    const page = renderPage({ date, today, found, body });
    const res = html(page, 200, { "Cache-Control": "public, max-age=120" });
    ctx.waitUntil(cache.put(cacheKey, res.clone()));
    return withCookie(res, key);
  },
};

// --------------------------------------------------------------------------
// GitHub (same shape as the widget Worker)
// --------------------------------------------------------------------------
async function ghRaw(repo, path, ref, token) {
  const api = `https://api.github.com/repos/${repo}/contents/${encodeURI(path)}?ref=${encodeURIComponent(ref)}`;
  const r = await fetch(api, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github.raw",
      "User-Agent": "daily-loop-worker",
    },
  });
  if (!r.ok) throw new Error(`GitHub ${r.status} for ${path}`);
  return await r.text();
}

// --------------------------------------------------------------------------
// Page
// --------------------------------------------------------------------------
function renderPage({ date, today, found, body }) {
  const prev = shiftDate(date, -1);
  const next = shiftDate(date, +1);
  const nextLink = next <= today ? `<a class="nav" href="?date=${next}">${next} →</a>` : `<span class="nav off">→</span>`;
  const isToday = date === today;
  const title = isToday ? "Today" : date;

  const content = found
    ? mdToHtml(body)
    : `<div class="empty"><p>Nothing captured for <b>${date}</b> yet.</p>
       <p class="hint">Talk into the “Daily Note” shortcut and it’ll land here within a few minutes.</p></div>`;

  return `<!doctype html><html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
<meta name="apple-mobile-web-app-title" content="Daily">
<meta name="color-scheme" content="light dark">
<title>${title} — Daily</title>
<style>${CSS}</style>
</head><body>
<header>
  <div class="bar">
    <a class="nav" href="?date=${prev}">← ${prev}</a>
    <button class="today" onclick="location.href='?date=${today}'">${isToday ? "Today" : "Jump to today"}</button>
    ${nextLink}
  </div>
  <h1 class="day">${isToday ? "Today" : date}<span class="dow">${dow(date)}</span></h1>
</header>
<main>${content}</main>
<footer><span>Daily Loop · yours, end to end</span></footer>
</body></html>`;
}

function landing() {
  return `<!doctype html><meta charset="utf-8"><title>Daily</title>
  <body style="font-family:system-ui;max-width:30rem;margin:4rem auto;padding:0 1rem">
  <h1>Daily Loop</h1><p>Go to <code>/daily?key=…</code>.</p></body>`;
}

// --------------------------------------------------------------------------
// Minimal, safe markdown → HTML (escape-first; no raw HTML passthrough)
// --------------------------------------------------------------------------
function mdToHtml(md) {
  const lines = md.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let inList = false, quote = null, para = [];

  const closeList = () => { if (inList) { out.push("</ul>"); inList = false; } };
  const closeQuote = () => { if (quote !== null) { out.push(`<blockquote>${quote}</blockquote>`); quote = null; } };
  const flushPara = () => { if (para.length) { out.push(`<p>${para.map(inline).join("<br>")}</p>`); para = []; } };
  const closeAll = () => { flushPara(); closeList(); closeQuote(); };

  for (const raw of lines) {
    const line = raw.replace(/\s+$/, "");

    if (/^\s*$/.test(line)) { closeAll(); continue; }
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(line.trim())) { closeAll(); out.push("<hr>"); continue; }

    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { closeAll(); const n = h[1].length; out.push(`<h${n}>${inline(h[2])}</h${n}>`); continue; }

    const q = line.match(/^>\s?(.*)$/);
    if (q) { flushPara(); closeList(); quote = (quote === null ? "" : quote + "<br>") + inline(q[1]); continue; }
    closeQuote();

    const li = line.match(/^\s*[-*]\s+(.*)$/);
    if (li) { flushPara(); if (!inList) { out.push("<ul>"); inList = true; } out.push(`<li>${inline(li[1])}</li>`); continue; }
    closeList();

    para.push(line);
  }
  closeAll();
  return out.join("\n");
}

function inline(s) {
  let t = esc(s);
  t = t.replace(/`([^`]+)`/g, (_, c) => `<code>${c}</code>`);
  t = t.replace(/\[([^\]]+)\]\((https?:\/\/[^\s)]+)\)/g, (_, txt, href) => `<a href="${href}" rel="noopener">${txt}</a>`);
  t = t.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  t = t.replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>");
  t = t.replace(/(^|\s)_([^_]+)_(?=\s|$|[.,;:!?])/g, "$1<em>$2</em>");
  return t;
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) =>
    ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
}

// --------------------------------------------------------------------------
// Dates
// --------------------------------------------------------------------------
function todayIn(tz) {
  // en-CA gives YYYY-MM-DD
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date());
}
function normalizeDate(s) { return s && /^\d{4}-\d{2}-\d{2}$/.test(s) ? s : null; }
function shiftDate(ymd, days) {
  const d = new Date(`${ymd}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}
function dow(ymd) {
  return new Intl.DateTimeFormat("en-US", { weekday: "short", timeZone: "UTC" }).format(new Date(`${ymd}T12:00:00Z`));
}

// --------------------------------------------------------------------------
// HTTP helpers
// --------------------------------------------------------------------------
function html(bodyStr, status = 200, extra = {}) {
  return new Response(bodyStr, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8", "X-Content-Type-Options": "nosniff", ...extra },
  });
}
function withCookie(res, key) {
  // Remember the key for ~180 days so the home-screen icon opens without ?key=.
  const r = new Response(res.body, res);
  r.headers.append("Set-Cookie", `dk=${key}; Max-Age=15552000; Path=/; HttpOnly; Secure; SameSite=Lax`);
  return r;
}
function cookie(request, name) {
  const c = request.headers.get("Cookie") || "";
  const m = c.match(new RegExp(`(?:^|;\\s*)${name}=([^;]+)`));
  return m ? m[1] : null;
}
function pickVars(env) {
  const out = {};
  for (const k of ["GITHUB_REPO", "GITHUB_BRANCH", "DAILY_DIR", "TZNAME"]) if (env[k]) out[k] = env[k];
  return out;
}
function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const CSS = `
:root{--bg:#fff;--fg:#1a1a1a;--mut:#6b7280;--line:#e5e7eb;--accent:#2563eb;--card:#f9fafb;--quote:#f3f4f6}
@media (prefers-color-scheme:dark){:root{--bg:#0b0c10;--fg:#e8eaed;--mut:#9aa0a6;--line:#23262d;--accent:#6ea8fe;--card:#14161b;--quote:#14161b}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
  padding:env(safe-area-inset-top) 0 calc(env(safe-area-inset-bottom) + 2rem)}
header{position:sticky;top:0;background:var(--bg);border-bottom:1px solid var(--line);padding:.5rem 1rem .25rem;z-index:5}
.bar{display:flex;align-items:center;justify-content:space-between;gap:.5rem;font-size:.8rem}
.nav{color:var(--accent);text-decoration:none;white-space:nowrap}
.nav.off{color:var(--line)}
.today{font:inherit;font-size:.8rem;border:1px solid var(--line);background:var(--card);color:var(--fg);
  border-radius:999px;padding:.25rem .7rem}
h1.day{margin:.4rem 0 .2rem;font-size:1.6rem;display:flex;align-items:baseline;gap:.6rem}
h1.day .dow{font-size:.85rem;font-weight:500;color:var(--mut)}
main{padding:1rem 1.1rem;max-width:42rem;margin:0 auto}
main h1{font-size:1.3rem;margin:1.4rem 0 .6rem}
main h2{font-size:1.02rem;margin:1.6rem 0 .1rem;color:var(--fg);border-top:1px solid var(--line);padding-top:1rem}
main h3{font-size:.95rem;margin:1rem 0 .3rem}
main p{margin:.5rem 0}
main em{color:var(--mut);font-style:normal;font-size:.8rem}
ul{margin:.4rem 0;padding-left:1.2rem}
li{margin:.15rem 0}
blockquote{margin:.5rem 0;padding:.5rem .8rem;background:var(--quote);border-left:3px solid var(--line);
  border-radius:6px;color:var(--mut);font-size:.93rem}
code{background:var(--card);border:1px solid var(--line);border-radius:5px;padding:.05rem .3rem;font-size:.82em}
hr{border:0;height:0;margin:1.2rem 0}
.empty{margin-top:3rem;text-align:center;color:var(--mut)}
.hint{font-size:.85rem}
a{color:var(--accent)}
footer{max-width:42rem;margin:2rem auto 0;padding:1rem;color:var(--mut);font-size:.72rem;text-align:center}
`;
