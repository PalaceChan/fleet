/* frev browser: one report pane, one conversation rail.
 *
 * Everything shown comes from the server's JSON; all text goes through textContent
 * or the safe Markdown renderer.  Drafts (composer text, queue, open comment
 * editors, unsent outbox) live in localStorage per session and survive reload.
 * Polling is a cheap GET /state every few seconds and on tab focus; it never
 * asks a model for anything.
 *
 * Keys: Enter in the composer queues a message; Shift+Enter inserts a newline;
 * Ctrl/Cmd+Enter sends the round (queued items + a non-empty composer).  In a
 * comment editor, Enter queues the comment and Esc closes it.  Option buttons
 * queue a pick; clicking the picked option again removes it.
 */
(function () {
  "use strict";

  var md = window.frevMarkdown;
  var $ = function (id) { return document.getElementById(id); };
  var m = /^\/s\/([^/]+)\/([^/]+)\/([^/]+)\/$/.exec(location.pathname);
  if (!m) { $("report-inner").textContent = "This page needs a session URL like /s/<namespace>/<root>/<session>/."; return; }
  var API = "/api/s/" + m[1] + "/" + m[2] + "/" + m[3];
  var STORE_KEY = "frev:" + m[1] + "/" + m[2] + "/" + m[3];
  var POLL_MS = 5000;

  var state = {
    session: null,          // status view from /session
    review: null,           // head revision
    revs: {},               // every fetched revision by number (labels for older rounds)
    draft: { queue: [], composer: "", comments: {}, outbox: null, seenHead: 0, open: {} },
    sending: false,
    storageOk: true,
    lastError: null
  };

  // ---------------------------------------------------------------- storage

  function loadDraft() {
    try {
      var raw = localStorage.getItem(STORE_KEY);
      if (raw) {
        var d = JSON.parse(raw);
        state.draft = Object.assign(state.draft, d);
        if (!Array.isArray(state.draft.queue)) state.draft.queue = [];
      }
    } catch (e) { state.storageOk = false; }
  }
  function saveDraft() {
    try { localStorage.setItem(STORE_KEY, JSON.stringify(state.draft)); state.storageOk = true; }
    catch (e) { state.storageOk = false; renderBadge(); }
  }

  // ---------------------------------------------------------------- helpers

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) e.className = cls;
    if (text !== undefined && text !== null) e.textContent = text;
    return e;
  }
  function button(label, cls, onClick, title) {
    var b = el("button", cls, label);
    b.type = "button";
    if (title) b.title = title;
    b.addEventListener("click", onClick);
    return b;
  }
  function fmtTime(iso) {
    if (!iso) return "";
    var d = new Date(iso);
    if (isNaN(d)) return iso;
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }
  function toast(text, ms) {
    var t = $("toast");
    t.textContent = text;
    t.hidden = false;
    clearTimeout(toast._t);
    toast._t = setTimeout(function () { t.hidden = true; }, ms || 3200);
  }
  function uuid() {
    if (crypto.randomUUID) return crypto.randomUUID();
    var a = new Uint8Array(16); crypto.getRandomValues(a);
    return Array.from(a, function (b) { return ("0" + b.toString(16)).slice(-2); }).join("");
  }
  function inputId() { return "in-" + uuid().slice(0, 8); }
  function confirmDialog(title, text, okLabel) {
    return new Promise(function (resolve) {
      var dlg = $("confirm");
      $("confirm-title").textContent = title;
      $("confirm-text").textContent = text;
      $("confirm-ok").textContent = okLabel || "OK";
      dlg.returnValue = "cancel";
      dlg.addEventListener("close", function onClose() {
        dlg.removeEventListener("close", onClose);
        resolve(dlg.returnValue === "ok");
      });
      dlg.showModal();
    });
  }
  function api(path, opts) {
    return fetch(API + path, Object.assign({ cache: "no-store", credentials: "omit" }, opts || {})).then(function (r) {
      return r.json().then(function (j) { return { status: r.status, body: j }; });
    });
  }

  function needsYou(item) {
    return (item.choices && item.choices.length) || item.phase === "decision" || (item.attention && item.attention.trim());
  }
  function findItem(id, rev) {
    return ((rev || state.review) && (rev || state.review).items || []).find(function (i) { return i.id === id; });
  }
  function findChoice(id, rev) {
    var out = null;
    ((rev || state.review) && (rev || state.review).items || []).forEach(function (i) {
      (i.choices || []).forEach(function (c) { if (c.id === id) out = { item: i, choice: c }; });
    });
    return out;
  }
  function ensureRevisions(numbers) {
    var missing = numbers.filter(function (n) { return n > 0 && !state.revs[n]; });
    return Promise.all(missing.map(function (n) {
      return api("/revision/" + n).then(function (r) { if (r.status === 200) state.revs[n] = r.body; });
    }));
  }
  function queuedPick(choiceId) {
    return state.draft.queue.find(function (q) { return q.type === "choice" && q.choice_id === choiceId; });
  }
  function isEnded() { return state.session && state.session.session.state === "ended"; }
  function awaitingCommander() { return state.session && state.session.session.state === "awaiting-commander"; }

  // ---------------------------------------------------------------- queue mutations

  function queueMessage(text) {
    text = (text || "").trim();
    if (!text) return false;
    state.draft.queue.push({ id: inputId(), type: "message", text: text });
    state.draft.composer = "";
    saveDraft();
    renderRail();
    return true;
  }
  function queueComment(itemId, text) {
    text = (text || "").trim();
    if (!text) return false;
    state.draft.queue.push({ id: inputId(), type: "comment", anchor_id: itemId, text: text });
    delete state.draft.comments[itemId];
    delete state.draft.open[itemId];
    saveDraft();
    renderAll();
    return true;
  }
  function togglePick(choiceId, optionId) {
    var existing = queuedPick(choiceId);
    if (existing && existing.option_id === optionId) {
      state.draft.queue = state.draft.queue.filter(function (q) { return q !== existing; });
    } else {
      state.draft.queue = state.draft.queue.filter(function (q) { return !(q.type === "choice" && q.choice_id === choiceId); });
      state.draft.queue.push({ id: inputId(), type: "choice", choice_id: choiceId, option_id: optionId });
    }
    saveDraft();
    renderAll();
  }
  function removeQueued(id) {
    state.draft.queue = state.draft.queue.filter(function (q) { return q.id !== id; });
    saveDraft();
    renderAll();
  }

  // ---------------------------------------------------------------- send / end

  function buildSubmission(kind) {
    var inputs = state.draft.queue.slice();
    var text = ($("composer-text").value || "").trim();
    if (text) inputs.push({ id: inputId(), type: "message", text: text });
    return { id: uuid(), revision: state.review.revision, kind: kind, inputs: inputs, client: "frev-browser/1" };
  }

  function sendRound() {
    if (state.sending || !state.review) return;
    if (isEnded()) { toast("The session has ended."); return; }
    if (awaitingCommander()) { toast("The commander has this round; wait for the next revision."); return; }
    var sub = buildSubmission("feedback");
    if (!sub.inputs.length) { toast("Nothing to send: pick an option, comment, or write a message first."); return; }
    post(sub);
  }

  function endSession() {
    if (state.sending || !state.review) return;
    if (isEnded()) { toast("Already ended."); return; }
    var sub = buildSubmission("end");
    var n = sub.inputs.length;
    if (awaitingCommander() && n) {
      toast("A round is with the commander. End can only close now; remove queued items or wait for the reply.");
      return;
    }
    var text = n ? "End the session and send the " + n + " queued item" + (n > 1 ? "s" : "") + " with it? Ending grants no approval and cancels no work."
                 : "End the session? Ending grants no approval and cancels no work. A later /frev starts a fresh one.";
    confirmDialog("End session", text, "End session").then(function (ok) { if (ok) post(sub); });
  }

  function post(sub) {
    state.sending = true;
    state.draft.outbox = sub;      // durable before the POST: a lost answer retries the same id
    saveDraft();
    renderBadge(); renderRail();
    return api("/submit", { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(sub) })
      .then(function (r) {
        state.sending = false;
        if (r.status === 200 && r.body.ok) {
          state.draft.outbox = null;
          if (sub.kind === "feedback" || sub.inputs.length) { state.draft.queue = []; state.draft.composer = ""; $("composer-text").value = ""; }
          saveDraft();
          state.lastError = null;
          toast(sub.kind === "end" ? "Session ended." : (r.body.replayed ? "Round already received." : "Round sent."));
          return refresh(true);
        }
        // Refused: keep the draft intact, explain.
        state.draft.outbox = null;
        saveDraft();
        var msg = r.body && r.body.message ? r.body.message : ("HTTP " + r.status);
        if (r.body && r.body.code === "stale-revision") msg = "The review was updated (revision " + r.body.head + "). Your queue is kept; check it against the new revision, then Send again.";
        if (r.body && r.body.errors) msg += " — " + r.body.errors.join("; ");
        state.lastError = msg;
        toast(msg, 6000);
        return refresh(true);
      })
      .catch(function (e) {
        state.sending = false;
        state.lastError = "No answer from the review server (" + e.message + "). The round is kept and will be retried with the same id.";
        renderBadge(); renderRail();
        toast(state.lastError, 6000);
      });
  }

  function retryOutbox() {
    if (state.draft.outbox && !state.sending) {
      var sub = state.draft.outbox;
      if (state.review && sub.revision !== state.review.revision) { state.draft.outbox = null; saveDraft(); return; }
      post(sub);
    }
  }

  function retryNotify(submissionId) {
    api("/notify/" + encodeURIComponent(submissionId), { method: "POST", headers: { "Content-Type": "application/json" }, body: "{}" })
      .then(function (r) {
        if (r.status === 200) toast(r.body.submission.notify.result === "queued" ? "Commander notified." : "Still not delivered: " + (r.body.submission.notify.reason || r.body.submission.notify.code), 5000);
        else toast(r.body.message || ("HTTP " + r.status), 5000);
        return refresh(true);
      });
  }

  // ---------------------------------------------------------------- refresh / poll

  var pollTimer = null;
  function schedulePoll() {
    clearTimeout(pollTimer);
    if (isEnded() && !state.session.pending_submission_id) return; // nothing more will change
    pollTimer = setTimeout(function () { refresh(false); }, POLL_MS);
  }

  function refresh(full) {
    return api("/state").then(function (r) {
      if (r.status !== 200) { schedulePoll(); return; }
      var st = r.body;
      var headChanged = !state.review || st.head !== state.review.revision;
      var stateChanged = !state.session || st.state !== state.session.session.state ||
        JSON.stringify(st.submissions) !== JSON.stringify(state.session.submissions.map(function (s) { return { id: s.id, seq: s.seq, kind: s.kind, notify: s.notify }; }));
      if (!(full || headChanged || stateChanged)) { schedulePoll(); return; }
      return api("/session").then(function (s) {
        if (s.status !== 200) { schedulePoll(); return; }
        state.session = s.body;
        var head = s.body.session.head;
        var wanted = s.body.submissions.map(function (x) { return x.revision; }).concat([head]);
        return ensureRevisions(wanted).then(function () {
          var wasRevision = state.review ? state.review.revision : 0;
          if (head > 0 && state.revs[head]) state.review = state.revs[head];
          renderAll();
          if (state.review && wasRevision && state.review.revision > wasRevision) {
            toast("Updated: the commander published revision " + state.review.revision + ".", 5000);
          }
          if (state.review) { state.draft.seenHead = state.review.revision; saveDraft(); }
          schedulePoll();
        });
      });
    }).catch(function () { schedulePoll(); });
  }

  // ---------------------------------------------------------------- render: report

  function renderAll() { renderBadge(); renderReport(); renderRail(); }

  function renderBadge() {
    var b = $("state-badge");
    b.className = "badge";
    var text;
    if (!state.session) text = "loading…";
    else if (state.sending) { text = "Sending…"; b.classList.add("busy"); }
    else if (isEnded()) text = "Session ended";
    else if (state.session.session.state === "authoring") text = "Commander is authoring…";
    else if (awaitingCommander()) { text = "Sent · awaiting commander"; b.classList.add("sent", "busy"); }
    else if (state.draft.queue.length) { text = "Draft · " + state.draft.queue.length + " queued, not sent"; b.classList.add("draft"); }
    else text = "Your turn";
    if (!state.storageOk) { text += " · drafts not saved (storage unavailable)"; b.classList.add("attention"); }
    b.textContent = "";
    var dot = el("span", "dot"); b.appendChild(dot);
    b.appendChild(document.createTextNode(text));
  }

  function renderReport() {
    var root = $("report-inner");
    root.textContent = "";
    if (!state.session) return;
    var s = state.session.session;
    $("top-title").textContent = "frev · " + (s.root && s.root.name ? s.root.name : "");
    $("top-meta").textContent = "session " + s.id + (s.observed_at ? " · observed " + fmtTime(s.observed_at) : "");
    if (!state.review) {
      root.appendChild(el("p", "muted", "The commander has not published a revision yet. This page checks for one every few seconds."));
      return;
    }
    var r = state.review;
    var head = el("div", "review-head");
    head.appendChild(el("h1", null, r.title));
    head.appendChild(el("p", "summary", r.summary));
    var facts = el("div", "facts");
    facts.appendChild(el("span", null, "revision " + r.revision + " · published " + fmtTime(r.published_at)));
    if (r.final) facts.appendChild(el("span", null, "final (read-only)"));
    var counts = summarizeCounts(r);
    facts.appendChild(el("span", null, counts));
    head.appendChild(facts);
    root.appendChild(head);
    if (r.note) {
      var note = el("div", "note");
      note.appendChild(el("div", "small muted", "Commander's note for this revision"));
      note.appendChild(md.render(document, r.note));
      root.appendChild(note);
    }
    var groups = { need: [], motion: [], parked: [] };
    (r.items || []).forEach(function (item) {
      if (needsYou(item)) groups.need.push(item);
      else if (item.phase === "done" || item.phase === "deferred") groups.parked.push(item);
      else groups.motion.push(item);
    });
    section(root, "Needs you", groups.need, "need", true);
    section(root, "In motion", groups.motion, null, false);
    section(root, "Parked & finished", groups.parked, null, false);
  }

  function summarizeCounts(r) {
    var q = 0, withChoices = 0, attention = 0;
    (r.items || []).forEach(function (i) {
      if (i.choices && i.choices.length) { withChoices++; q += i.choices.length; }
      if (i.attention && i.attention.trim()) attention++;
    });
    var parts = [];
    if (q) parts.push(q + " question" + (q > 1 ? "s" : "") + " across " + withChoices + " item" + (withChoices > 1 ? "s" : ""));
    if (attention) parts.push(attention + " other ask" + (attention > 1 ? "s" : ""));
    if (!parts.length) parts.push("nothing needs you in this revision");
    return parts.join(" · ");
  }

  function section(root, title, items, cls, expanded) {
    var h = el("h2", "section-title" + (cls ? " " + cls : ""));
    h.appendChild(document.createTextNode(title));
    h.appendChild(el("span", "count", "(" + items.length + ")"));
    root.appendChild(h);
    if (!items.length) { root.appendChild(el("p", "empty", title === "Needs you" ? "Nothing needs you right now." : "Nothing here.")); return; }
    items.forEach(function (item) { root.appendChild(card(item, expanded)); });
  }

  function card(item, expanded) {
    var c = el("article", "card" + (needsYou(item) ? " need" : " compact"));
    c.id = "item-" + item.id;
    var head = el("div", "card-head");
    head.appendChild(el("h3", null, item.title));
    head.appendChild(el("span", "chip", item.owner));
    head.appendChild(el("span", "chip phase-" + item.phase, item.phase));
    c.appendChild(head);
    c.appendChild(el("p", "summary", item.summary));
    if (item.attention && item.attention.trim()) {
      var a = el("div", "attention");
      a.appendChild(el("strong", null, "Ask:"));
      a.appendChild(document.createTextNode(item.attention));
      c.appendChild(a);
    }
    (item.choices || []).forEach(function (choice) { c.appendChild(choiceBlock(choice)); });

    var actions = el("div", "card-actions");
    var commentBtn = button(state.draft.open[item.id] ? "Close comment" : "Comment", "small", function () {
      if (state.draft.open[item.id]) delete state.draft.open[item.id]; else state.draft.open[item.id] = true;
      saveDraft(); renderReport();
      if (state.draft.open[item.id]) { var ta = document.querySelector("#item-" + cssEscape(item.id) + " textarea"); if (ta) ta.focus(); }
    }, "Queue a comment anchored to this item");
    actions.appendChild(commentBtn);
    var hasBody = (item.body && item.body.trim()) || (item.source_refs && item.source_refs.length) || (item.depends_on && item.depends_on.length);
    if (hasBody) {
      var open = expanded ? state.draft.open["d:" + item.id] !== false : !!state.draft.open["d:" + item.id];
      actions.appendChild(button(open ? "Hide details" : "Details", "small ghost", function () {
        state.draft.open["d:" + item.id] = !open; saveDraft(); renderReport();
      }));
      if (open) {
        var d = el("div", "details");
        if (item.body && item.body.trim()) d.appendChild(md.render(document, item.body));
        var refs = [];
        if (item.depends_on && item.depends_on.length) refs.push("depends on: " + item.depends_on.join(", "));
        if (item.source_refs && item.source_refs.length) refs.push("evidence: " + item.source_refs.join(", "));
        if (refs.length) d.appendChild(el("div", "refs", refs.join(" · ")));
        c.appendChild(actions);
        c.appendChild(d);
      } else c.appendChild(actions);
    } else c.appendChild(actions);

    var queuedComments = state.draft.queue.filter(function (q) { return q.type === "comment" && q.anchor_id === item.id; });
    if (queuedComments.length) {
      var qc = el("div", "small muted");
      qc.textContent = queuedComments.length + " comment" + (queuedComments.length > 1 ? "s" : "") + " queued on this item (see the rail)";
      c.appendChild(qc);
    }
    if (state.draft.open[item.id]) c.appendChild(commentEditor(item));
    return c;
  }

  function cssEscape(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^A-Za-z0-9_-]/g, "\\$&"); }

  function choiceBlock(choice) {
    var wrap = el("div", "choice");
    wrap.setAttribute("role", "group");
    wrap.appendChild(el("p", "question", choice.question));
    var opts = el("div", "options");
    var picked = queuedPick(choice.id);
    var decided = !!lockedPick(choice.id);
    choice.options.forEach(function (o) {
      var b = el("button", "option" + (picked && picked.option_id === o.id ? " picked" : "") + (decided ? " decided" : ""));
      b.type = "button";
      b.setAttribute("aria-pressed", picked && picked.option_id === o.id ? "true" : "false");
      b.appendChild(el("span", "radio"));
      b.appendChild(el("span", null, o.label));
      if (choice.recommendation === o.id) b.appendChild(el("span", "rec", "recommended"));
      b.addEventListener("click", function () {
        if (isEnded()) { toast("The session has ended."); return; }
        if (awaitingCommander()) { toast("The commander has a round in hand; picks queue for the next revision."); }
        togglePick(choice.id, o.id);
      });
      opts.appendChild(b);
    });
    wrap.appendChild(opts);
    if (decided) wrap.appendChild(el("div", "small muted", "You already answered this in round " + lockedPick(choice.id).seq + "; the commander accounts for it in the next revision."));
    return wrap;
  }

  function lockedPick(choiceId) {
    // A pick sent in the round the commander is still handling.
    if (!awaitingCommander() || !state.session) return null;
    var pending = state.session.submissions.find(function (s) { return s.id === state.session.pending_submission_id; });
    if (!pending) return null;
    var hit = pending.inputs.find(function (i) { return i.type === "choice" && i.choice_id === choiceId; });
    return hit ? { seq: pending.seq, option_id: hit.option_id } : null;
  }

  function commentEditor(item) {
    var wrap = el("div", "comment-editor");
    var ta = el("textarea");
    ta.rows = 2;
    ta.placeholder = "Comment on “" + item.title + "”… Enter queues, Esc closes";
    ta.value = state.draft.comments[item.id] || "";
    ta.addEventListener("input", function () { state.draft.comments[item.id] = ta.value; saveDraft(); });
    ta.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter" && !ev.shiftKey) { ev.preventDefault(); if (!queueComment(item.id, ta.value)) toast("Write something first."); }
      if (ev.key === "Escape") { delete state.draft.open[item.id]; saveDraft(); renderReport(); }
    });
    wrap.appendChild(ta);
    var row = el("div", "buttons");
    row.appendChild(button("Queue comment", "small primary", function () { if (!queueComment(item.id, ta.value)) toast("Write something first."); }));
    row.appendChild(button("Cancel", "small ghost", function () { delete state.draft.open[item.id]; saveDraft(); renderReport(); }));
    wrap.appendChild(row);
    return wrap;
  }

  // ---------------------------------------------------------------- render: rail

  function renderRail() {
    renderTimeline();
    renderQueue();
    renderNotify();
    renderComposer();
  }

  function dispositionFor(inputId) {
    var out = null;
    (state.session.revisions || []).forEach(function (rev) {
      (rev.dispositions || []).forEach(function (d) { if (d.input_id === inputId) out = d; });
    });
    return out;
  }

  function describeInput(inp, revisionNumber) {
    var rev = state.revs[revisionNumber] || null;
    var li = el("li");
    if (inp.type === "choice") {
      var found = rev ? findChoice(inp.choice_id, rev) : null;
      var label = inp.option_id;
      if (found) { var o = found.choice.options.find(function (x) { return x.id === inp.option_id; }); if (o) label = o.label; }
      li.appendChild(el("span", "small", (found ? found.item.title + " — " : "") + "picked: "));
      li.appendChild(el("strong", null, label));
    } else if (inp.type === "comment") {
      var it = rev ? findItem(inp.anchor_id, rev) : null;
      li.appendChild(el("span", "small", "on " + (it ? it.title : inp.anchor_id) + ": "));
      li.appendChild(document.createTextNode(inp.text));
    } else {
      li.appendChild(document.createTextNode(inp.text));
    }
    return li;
  }

  function renderTimeline() {
    var tl = $("timeline");
    var atBottom = tl.scrollHeight - tl.scrollTop - tl.clientHeight < 40;
    tl.textContent = "";
    if (!state.session) return;
    var events = [];
    (state.session.revisions || []).forEach(function (r) { events.push({ at: r.published_at, kind: "revision", rev: r }); });
    (state.session.submissions || []).forEach(function (s) { events.push({ at: s.received_at, kind: "round", sub: s }); });
    events.sort(function (a, b) { return (a.at || "").localeCompare(b.at || ""); });
    if (!events.length) tl.appendChild(el("div", "msg system", "No revision yet."));
    events.forEach(function (ev) {
      if (ev.kind === "revision") {
        var r = ev.rev;
        var msg = el("div", "msg commander");
        var who = el("div", "who");
        who.appendChild(el("span", null, "Commander · revision " + r.revision + (r.final ? " (final)" : "")));
        who.appendChild(el("span", null, fmtTime(r.published_at)));
        msg.appendChild(who);
        if (r.note) msg.appendChild(md.render(document, r.note));
        else msg.appendChild(el("div", "muted small", r.revision === 1 ? "Published the review." : "Published an updated review."));
        if (r.dispositions && r.dispositions.length) {
          var ul = el("ul");
          r.dispositions.forEach(function (d) {
            var li = el("li");
            li.appendChild(el("span", "disp " + d.status, d.status));
            li.appendChild(document.createTextNode(d.note));
            ul.appendChild(li);
          });
          msg.appendChild(ul);
        }
        tl.appendChild(msg);
      } else {
        var s = ev.sub;
        var pending = s.id === state.session.pending_submission_id;
        var um = el("div", "msg user" + (pending ? " pending" : ""));
        var uw = el("div", "who");
        uw.appendChild(el("span", null, (s.kind === "end" ? "You ended the session" : "You · round " + s.seq) + " · on revision " + s.revision));
        uw.appendChild(el("span", null, fmtTime(s.received_at)));
        um.appendChild(uw);
        if (s.inputs.length) {
          var ul2 = el("ul");
          s.inputs.forEach(function (inp) {
            var li = describeInput(inp, s.revision);
            var d = dispositionFor(inp.id);
            if (d) { var tag = el("span", "disp " + d.status, d.status); tag.title = d.note; li.insertBefore(tag, li.firstChild); }
            ul2.appendChild(li);
          });
          um.appendChild(ul2);
        }
        if (pending) um.appendChild(el("div", "small muted", s.kind === "end" ? "Closing; the commander may add a final note." : "Awaiting the commander's revision…"));
        tl.appendChild(um);
      }
    });
    if (isEnded()) tl.appendChild(el("div", "msg system", "Session ended. Run /frev in the commander's chat for a fresh one."));
    if (atBottom) tl.scrollTop = tl.scrollHeight;
  }

  function renderQueue() {
    var q = $("queue");
    q.textContent = "";
    var items = state.draft.queue;
    var title = el("div", "queue-title" + (items.length ? "" : " empty-title"));
    title.appendChild(el("span", null, items.length ? "Queued — not sent yet (" + items.length + ")" : "Queue empty"));
    if (items.length) title.appendChild(button("Clear", "small ghost", function () {
      confirmDialog("Clear queue", "Remove all " + items.length + " queued items? Nothing has been sent.", "Clear").then(function (ok) {
        if (ok) { state.draft.queue = []; saveDraft(); renderAll(); }
      });
    }));
    q.appendChild(title);
    items.forEach(function (inp) {
      var row = el("div", "qitem");
      row.appendChild(el("span", "kind", inp.type === "choice" ? "pick" : inp.type));
      var body = el("div", "body");
      if (inp.type === "choice") {
        var f = findChoice(inp.choice_id);
        var lab = inp.option_id;
        if (f) { var o = f.choice.options.find(function (x) { return x.id === inp.option_id; }); if (o) lab = o.label; }
        body.appendChild(el("div", "anchor", f ? f.item.title + " — " + f.choice.question : inp.choice_id + " (not in this revision)"));
        body.appendChild(document.createTextNode(lab));
      } else if (inp.type === "comment") {
        var it = findItem(inp.anchor_id);
        body.appendChild(el("div", "anchor", "on " + (it ? it.title : inp.anchor_id + " (not in this revision)")));
        body.appendChild(document.createTextNode(inp.text));
      } else body.appendChild(document.createTextNode(inp.text));
      row.appendChild(body);
      row.appendChild(button("✕", "small ghost remove", function () { removeQueued(inp.id); }, "Remove from queue"));
      q.appendChild(row);
    });
    if (state.draft.outbox && !state.sending) {
      var ob = el("div", "qitem");
      ob.appendChild(el("span", "kind", "unsent"));
      ob.appendChild(el("div", "body", "A round was prepared but the server did not confirm it."));
      ob.appendChild(button("Retry", "small primary", retryOutbox));
      q.appendChild(ob);
    }
  }

  function renderNotify() {
    var n = $("notify");
    n.textContent = "";
    if (!state.session) return;
    var last = state.session.submissions[state.session.submissions.length - 1];
    if (state.lastError) { n.appendChild(el("div", "fail", state.lastError)); }
    if (!last || !last.notify) return;
    var nt = last.notify;
    var line = el("div");
    if (nt.result === "queued" || nt.result === "replayed") {
      line.className = "ok";
      line.textContent = (last.kind === "end" ? "Closure" : "Round " + last.seq) + " delivered to Fleet: the commander is notified" + (nt.state ? " (message " + nt.state + ")" : "") + ".";
      if (nt.warnings && nt.warnings.length) line.textContent += " Note: " + nt.warnings.join("; ") + ".";
    } else {
      line.className = nt.result === "refused" ? "held" : "fail";
      line.textContent = (last.kind === "end" ? "Closure" : "Round " + last.seq) + " is saved but the commander was NOT notified (" + (nt.code || nt.result) + "): " + (nt.reason || "");
      if (nt.code !== "commander-replaced") line.appendChild(button("Retry notify", "small", function () { retryNotify(last.id); }));
    }
    n.appendChild(line);
  }

  function renderComposer() {
    var form = $("composer");
    var ta = $("composer-text");
    var ended = isEnded();
    var awaiting = awaitingCommander();
    if (document.activeElement !== ta) ta.value = state.draft.composer || "";
    ta.disabled = ended;
    form.classList.toggle("disabled", ended);
    $("queue-button").disabled = ended;
    $("send-button").disabled = ended || awaiting || state.sending || !state.review;
    $("end-button").disabled = ended || state.sending || !state.review;
    var n = state.draft.queue.length;
    $("send-button").textContent = n ? "Send round (" + n + ")" : "Send round";
    $("composer-hint").textContent = ended ? "Session ended." : awaiting ? "Commander is handling your round; queued items go with the next Send." : "Enter queues · Shift+Enter newline · Ctrl/⌘+Enter sends";
    $("rail-meta").textContent = state.session ? (state.session.submissions.length + " round" + (state.session.submissions.length === 1 ? "" : "s")) : "";
  }

  // ---------------------------------------------------------------- wiring

  function wire() {
    var ta = $("composer-text");
    ta.addEventListener("input", function () { state.draft.composer = ta.value; saveDraft(); });
    ta.addEventListener("keydown", function (ev) {
      if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) { ev.preventDefault(); sendRound(); return; }
      if (ev.key === "Enter" && !ev.shiftKey) {
        ev.preventDefault();
        if (queueMessage(ta.value)) { ta.value = ""; toast("Queued. Send round when ready (Ctrl+Enter)."); renderBadge(); }
      }
    });
    $("composer").addEventListener("submit", function (ev) {
      ev.preventDefault();
      if (queueMessage(ta.value)) { ta.value = ""; renderBadge(); } else toast("Write something first.");
    });
    $("send-button").addEventListener("click", sendRound);
    $("end-button").addEventListener("click", endSession);
    $("check-updates").addEventListener("click", function () { toast("Checking…", 1200); refresh(true); });
    $("theme-toggle").addEventListener("click", function () {
      var order = ["auto", "light", "dark"];
      var cur = document.documentElement.getAttribute("data-theme") || "auto";
      var next = order[(order.indexOf(cur) + 1) % order.length];
      document.documentElement.setAttribute("data-theme", next);
      try { localStorage.setItem("frev:theme", next); } catch (e) { /* fine */ }
      toast("Theme: " + next, 1200);
    });
    $("rail-toggle").addEventListener("click", function () {
      var hidden = document.querySelector(".layout").classList.toggle("rail-hidden");
      $("rail-toggle").setAttribute("aria-expanded", hidden ? "false" : "true");
    });
    document.addEventListener("visibilitychange", function () { if (document.visibilityState === "visible") refresh(false); });
    window.addEventListener("focus", function () { refresh(false); });
    try { var t = localStorage.getItem("frev:theme"); if (t) document.documentElement.setAttribute("data-theme", t); } catch (e) { /* fine */ }
  }

  loadDraft();
  wire();
  refresh(true).then(function () {
    if (state.draft.outbox) {
      // A round was prepared before a reload: retry the same id (replay-safe) if it still targets this revision.
      if (state.review && state.draft.outbox.revision === state.review.revision) retryOutbox();
      else { state.draft.outbox = null; saveDraft(); renderRail(); }
    }
  });
})();
