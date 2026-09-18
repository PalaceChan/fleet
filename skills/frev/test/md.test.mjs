// Safe Markdown renderer: node --test md.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const md = require("../app/static/md.js");

const texts = (nodes) => nodes.map((n) => n.t === "text" ? n.text : n.t === "code" ? "`" + n.text + "`" : "<" + n.t + ">" + texts(n.children || []) + "</" + n.t + ">").join("");

test("raw HTML is text, not markup", () => {
  const blocks = md.parseBlocks("Hello <script>alert(1)</script> <img src=x onerror=alert(2)>");
  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].t, "p");
  assert.equal(md.plainText(blocks[0].children), "Hello <script>alert(1)</script> <img src=x onerror=alert(2)>");
  assert.ok(blocks[0].children.every((n) => n.t === "text"));
});

test("only http(s) links survive; javascript:, data:, file: become text", () => {
  const inline = md.parseInline("[ok](https://example.test/x) [bad](javascript:alert(1)) [d](data:text/html,hi) [f](file:///etc/passwd)");
  const links = inline.filter((n) => n.t === "link");
  assert.equal(links.length, 1);
  assert.equal(links[0].href, "https://example.test/x");
  assert.match(md.plainText(inline), /bad \(javascript:alert\(1\)\)/);
  assert.match(md.plainText(inline), /f \(file:\/\/\/etc\/passwd\)/);
});

test("no image syntax: ![alt](url) is a bang plus a link, never an image node", () => {
  const inline = md.parseInline("![alt](http://evil.example/track.png)");
  assert.ok(!inline.some((n) => n.t === "img"));
  assert.equal(inline[0].t, "text");
  assert.equal(inline[0].text, "!");
});

test("blocks: headings, lists, fences, quotes, paragraphs", () => {
  const blocks = md.parseBlocks("# Title\n\nPara **bold** and *em* and `code`.\n\n- one\n- two\n\n1. a\n2. b\n\n```\n<b>raw</b>\n```\n\n> quoted");
  assert.deepEqual(blocks.map((b) => b.t), ["h", "p", "ul", "ol", "pre", "quote"]);
  assert.equal(blocks[0].level, 1);
  assert.equal(texts(blocks[1].children), "Para <strong>bold</strong> and <em>em</em> and `code`.");
  assert.equal(blocks[2].items.length, 2);
  assert.equal(blocks[4].text, "<b>raw</b>");
  assert.equal(blocks[5].children[0].t, "p");
});

test("render builds DOM with textContent only", () => {
  // A tiny document double: records element creation and text assignment.
  const made = [];
  const doc = {
    createDocumentFragment: () => ({ children: [], appendChild(c) { this.children.push(c); } }),
    createTextNode: (t) => ({ text: t }),
    createElement: (tag) => { const e = { tag, attrs: {}, children: [], textContent: null, setAttribute(k, v) { this.attrs[k] = v; }, appendChild(c) { this.children.push(c); } }; made.push(e); return e; },
  };
  const frag = md.render(doc, "<b>x</b> [l](javascript:alert(1)) [ok](https://a.b/)");
  assert.equal(frag.children.length, 1);
  const p = frag.children[0];
  assert.equal(p.tag, "p");
  assert.equal(p.children[0].text, "<b>x</b> ");
  const anchors = made.filter((e) => e.tag === "a");
  assert.equal(anchors.length, 1);
  assert.equal(anchors[0].attrs.href, "https://a.b/");
  assert.equal(anchors[0].attrs.rel, "noopener noreferrer");
  assert.ok(!made.some((e) => e.tag === "script" || e.tag === "img"));
});
