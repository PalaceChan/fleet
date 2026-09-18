/* Safe Markdown for frev: text in, a plain tree out, DOM built with textContent only.
 *
 * Supported: ATX headings, paragraphs, `-`/`*`/`1.` lists, fenced code, `>` quotes,
 * inline `code`, **strong**, *em*, [text](http(s) url).  Everything else is
 * literal text.  Raw HTML is text.  Links must be http(s); anything else is
 * rendered as text.  There are no images.
 *
 * Loads as a classic script (window.frevMarkdown) and as a CommonJS module (tests).
 */
(function (root, factory) {
  if (typeof module === "object" && module.exports) module.exports = factory();
  else root.frevMarkdown = factory();
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var SAFE_HREF = /^https?:\/\/[^\s<>"']+$/i;

  function parseInline(text) {
    var out = [];
    var i = 0;
    var buf = "";
    function flush() {
      if (buf) out.push({ t: "text", text: buf });
      buf = "";
    }
    while (i < text.length) {
      var ch = text[i];
      if (ch === "\\" && i + 1 < text.length) {
        buf += text[i + 1];
        i += 2;
        continue;
      }
      if (ch === "`") {
        var end = text.indexOf("`", i + 1);
        if (end > i) {
          flush();
          out.push({ t: "code", text: text.slice(i + 1, end) });
          i = end + 1;
          continue;
        }
      }
      if (text.startsWith("**", i)) {
        var e2 = text.indexOf("**", i + 2);
        if (e2 > i + 2) {
          flush();
          out.push({ t: "strong", children: parseInline(text.slice(i + 2, e2)) });
          i = e2 + 2;
          continue;
        }
      }
      if (ch === "*" || ch === "_") {
        var e1 = text.indexOf(ch, i + 1);
        if (e1 > i + 1 && text[i + 1] !== " ") {
          flush();
          out.push({ t: "em", children: parseInline(text.slice(i + 1, e1)) });
          i = e1 + 1;
          continue;
        }
      }
      if (ch === "[") {
        var close = text.indexOf("](", i + 1);
        var paren = close > 0 ? text.indexOf(")", close + 2) : -1;
        if (close > i && paren > close) {
          var label = text.slice(i + 1, close);
          var href = text.slice(close + 2, paren).trim();
          flush();
          if (SAFE_HREF.test(href)) out.push({ t: "link", href: href, children: parseInline(label) });
          else out.push({ t: "text", text: label + " (" + href + ")" });
          i = paren + 1;
          continue;
        }
      }
      buf += ch;
      i++;
    }
    flush();
    return out;
  }

  function parseBlocks(src) {
    var lines = String(src || "").replace(/\r\n?/g, "\n").split("\n");
    var blocks = [];
    var i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (/^\s*$/.test(line)) { i++; continue; }
      var fence = /^```/.exec(line);
      if (fence) {
        var code = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) code.push(lines[i++]);
        i++;
        blocks.push({ t: "pre", text: code.join("\n") });
        continue;
      }
      var h = /^(#{1,6})\s+(.*)$/.exec(line);
      if (h) {
        blocks.push({ t: "h", level: h[1].length, children: parseInline(h[2].trim()) });
        i++;
        continue;
      }
      if (/^>/.test(line)) {
        var q = [];
        while (i < lines.length && /^>/.test(lines[i])) q.push(lines[i++].replace(/^>\s?/, ""));
        blocks.push({ t: "quote", children: parseBlocks(q.join("\n")) });
        continue;
      }
      var li = /^\s*([-*]|\d+[.)])\s+(.*)$/.exec(line);
      if (li) {
        var ordered = /\d/.test(li[1]);
        var items = [];
        while (i < lines.length) {
          var m = /^\s*([-*]|\d+[.)])\s+(.*)$/.exec(lines[i]);
          if (!m || /\d/.test(m[1]) !== ordered) break;
          var item = m[2];
          i++;
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*([-*]|\d+[.)])\s+/.test(lines[i])) item += " " + lines[i++].trim();
          items.push(parseInline(item));
        }
        blocks.push({ t: ordered ? "ol" : "ul", items: items });
        continue;
      }
      var para = [];
      while (i < lines.length && !/^\s*$/.test(lines[i]) && !/^```/.test(lines[i]) && !/^(#{1,6})\s+/.test(lines[i]) && !/^>/.test(lines[i]) && !/^\s*([-*]|\d+[.)])\s+/.test(lines[i])) {
        para.push(lines[i++].trim());
      }
      blocks.push({ t: "p", children: parseInline(para.join(" ")) });
    }
    return blocks;
  }

  function inlineToDom(doc, nodes, parent) {
    nodes.forEach(function (n) {
      var el;
      if (n.t === "text") { parent.appendChild(doc.createTextNode(n.text)); return; }
      if (n.t === "code") { el = doc.createElement("code"); el.textContent = n.text; parent.appendChild(el); return; }
      if (n.t === "link") {
        el = doc.createElement("a");
        if (SAFE_HREF.test(n.href)) el.setAttribute("href", n.href);
        el.setAttribute("rel", "noopener noreferrer");
        el.setAttribute("target", "_blank");
        inlineToDom(doc, n.children, el);
        parent.appendChild(el);
        return;
      }
      el = doc.createElement(n.t === "strong" ? "strong" : "em");
      inlineToDom(doc, n.children, el);
      parent.appendChild(el);
    });
  }

  function blocksToDom(doc, blocks, parent) {
    blocks.forEach(function (b) {
      var el;
      if (b.t === "pre") {
        el = doc.createElement("pre");
        var code = doc.createElement("code");
        code.textContent = b.text;
        el.appendChild(code);
      } else if (b.t === "h") {
        el = doc.createElement("h" + Math.min(6, b.level + 2)); // headings inside a card start at h3
        inlineToDom(doc, b.children, el);
      } else if (b.t === "quote") {
        el = doc.createElement("blockquote");
        blocksToDom(doc, b.children, el);
      } else if (b.t === "ul" || b.t === "ol") {
        el = doc.createElement(b.t);
        b.items.forEach(function (it) {
          var li = doc.createElement("li");
          inlineToDom(doc, it, li);
          el.appendChild(li);
        });
      } else {
        el = doc.createElement("p");
        inlineToDom(doc, b.children, el);
      }
      parent.appendChild(el);
    });
    return parent;
  }

  function render(doc, src) {
    var frag = doc.createDocumentFragment();
    blocksToDom(doc, parseBlocks(src), frag);
    return frag;
  }

  function plainText(nodes) {
    return nodes.map(function (n) {
      if (n.t === "text" || n.t === "code") return n.text;
      return plainText(n.children || []);
    }).join("");
  }

  return { parseInline: parseInline, parseBlocks: parseBlocks, render: render, plainText: plainText, SAFE_HREF: SAFE_HREF };
});
