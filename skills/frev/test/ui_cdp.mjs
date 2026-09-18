// Light browser check for the frev UI over the Chrome DevTools Protocol.
// No packages: Node >= 22 ships WebSocket and fetch.  Run by test_ui.py, or by hand:
//   node ui_cdp.mjs <session url> <screenshot dir>
// Exits 0 and prints a JSON result when the checked sequence held; non-zero otherwise.

import { spawn } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [url, shotDir] = process.argv.slice(2);
if (!url) { console.error("usage: node ui_cdp.mjs URL [SHOTDIR]"); process.exit(2); }
const chromium = process.env.FREV_CHROMIUM || "chromium";
const port = 9300 + Math.floor(Math.random() * 500);
const profile = mkdtempSync(join(tmpdir(), "frev-cdp-"));
const chrome = spawn(chromium, ["--headless=new", "--no-sandbox", "--disable-gpu", "--hide-scrollbars", "--window-size=1400,1000",
  `--remote-debugging-port=${port}`, `--user-data-dir=${profile}`, "about:blank"], { stdio: "ignore" });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const results = {};
let ws, nextId = 1; const pending = new Map(); const events = [];

async function connect() {
  for (let i = 0; i < 100; i++) {
    try {
      const targets = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
      const page = targets.find((t) => t.type === "page");
      if (page) {
        ws = new WebSocket(page.webSocketDebuggerUrl);
        await new Promise((res, rej) => { ws.onopen = res; ws.onerror = rej; });
        ws.onmessage = (m) => {
          const msg = JSON.parse(m.data);
          if (msg.id && pending.has(msg.id)) { pending.get(msg.id)(msg); pending.delete(msg.id); }
          else if (msg.method) events.push(msg);
        };
        return;
      }
    } catch (e) { /* not up yet */ }
    await sleep(100);
  }
  throw new Error("chromium did not expose a page target");
}
function send(method, params = {}) {
  return new Promise((res) => { const id = nextId++; pending.set(id, res); ws.send(JSON.stringify({ id, method, params })); })
    .then((msg) => { if (msg.error) throw new Error(method + ": " + JSON.stringify(msg.error)); return msg.result; });
}
async function evaluate(expression) {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.exceptionDetails) throw new Error("page threw: " + JSON.stringify(r.exceptionDetails.exception?.description || r.exceptionDetails.text));
  return r.result.value;
}
async function waitFor(expression, what, timeout = 8000) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeout) {
    if (await evaluate(expression)) return true;
    await sleep(120);
  }
  throw new Error("timeout waiting for " + what);
}
async function shot(name) {
  if (!shotDir) return;
  const r = await send("Page.captureScreenshot", { format: "png" });
  writeFileSync(join(shotDir, name), Buffer.from(r.data, "base64"));
}
async function navigate(u) {
  await send("Page.navigate", { url: u });
  await waitFor("document.readyState === 'complete'", "load");
  await waitFor("!!document.querySelector('.card')", "review cards");
}
const badge = () => evaluate("document.getElementById('state-badge').textContent");
const queueCount = () => evaluate("document.querySelectorAll('.qitem').length");

try {
  await connect();
  await send("Page.enable");
  await send("Runtime.enable");
  await navigate(url);
  results.errorsOnLoad = events.filter((e) => e.method === "Runtime.exceptionThrown").length;
  results.badgeInitial = await badge();
  results.needsYouFirst = await evaluate("document.querySelector('.section-title').textContent.startsWith('Needs you')");
  results.rawHtmlEscaped = await evaluate("!document.querySelector('.card script, .card img, .card iframe') && document.body.innerHTML.indexOf('<script>alert') === -1");

  // 1. pick an option -> queued, shown picked, badge says draft
  await evaluate("document.querySelector('.option').click(); true");
  await waitFor("document.querySelectorAll('.qitem').length === 1", "pick queued");
  results.pickQueued = await evaluate("document.querySelector('.option').classList.contains('picked') && document.querySelector('.option').getAttribute('aria-pressed') === 'true'");
  // clicking the same option again removes the pick; re-pick for the round
  await evaluate("document.querySelector('.option').click(); true");
  await waitFor("document.querySelectorAll('.qitem').length === 0", "pick removed");
  await evaluate("document.querySelector('.option').click(); true");
  await waitFor("document.querySelectorAll('.qitem').length === 1", "pick queued again");

  // 2. Enter in the composer queues a message
  await evaluate(`(function(){ var ta=document.getElementById('composer-text'); ta.focus(); ta.value='Please keep the PR small.'; ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true})); return true; })()`);
  await waitFor("document.querySelectorAll('.qitem').length === 2", "message queued");
  results.composerClearedAfterQueue = (await evaluate("document.getElementById('composer-text').value")) === "";
  results.badgeDraft = await badge();

  // 3. a comment on the second card via its editor (Enter queues)
  await evaluate("document.querySelectorAll('.card')[1].querySelector('.card-actions button').click(); true");
  await waitFor("!!document.querySelector('.comment-editor textarea')", "comment editor");
  await evaluate(`(function(){ var ta=document.querySelector('.comment-editor textarea'); ta.value='Shorter opening, please.'; ta.dispatchEvent(new Event('input',{bubbles:true})); ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',bubbles:true,cancelable:true})); return true; })()`);
  await waitFor("document.querySelectorAll('.qitem').length === 3", "comment queued");
  await shot("draft.png");

  // 4. unsent composer text + queue survive a reload
  await evaluate(`(function(){ var ta=document.getElementById('composer-text'); ta.value='half-typed thought'; ta.dispatchEvent(new Event('input',{bubbles:true})); return true; })()`);
  await sleep(150);
  await navigate(url);
  results.queueAfterReload = await queueCount();
  results.composerAfterReload = await evaluate("document.getElementById('composer-text').value");
  results.pickStillShownAfterReload = await evaluate("document.querySelector('.option').classList.contains('picked')");

  // 5. Ctrl+Enter sends the round (queued items + the composer text)
  await evaluate(`(function(){ var ta=document.getElementById('composer-text'); ta.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',ctrlKey:true,bubbles:true,cancelable:true})); return true; })()`);
  await waitFor("document.getElementById('state-badge').textContent.indexOf('awaiting commander') !== -1", "sent badge", 15000);
  results.badgeSent = await badge();
  results.queueAfterSend = await queueCount();
  results.composerAfterSend = await evaluate("document.getElementById('composer-text').value");
  results.roundInputs = await evaluate("document.querySelectorAll('.msg.user li').length");
  results.notifyLine = await evaluate("document.getElementById('notify').textContent");
  results.sendDisabledWhilePending = await evaluate("document.getElementById('send-button').disabled");
  await shot("sent.png");
  results.errorsTotal = events.filter((e) => e.method === "Runtime.exceptionThrown").length;
  console.log(JSON.stringify(results));
} catch (e) {
  console.log(JSON.stringify({ ...results, failure: String(e.message || e) }));
  process.exitCode = 1;
} finally {
  try { ws?.close(); } catch (e) { /* closing */ }
  chrome.kill("SIGTERM");
  await sleep(200);
  rmSync(profile, { recursive: true, force: true });
}
