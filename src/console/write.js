// zerverg console: the Write view. Title, details and text in one
// place, with a live preview rendered by the server through the real
// layout and stylesheet. Saves Markdown (with a front matter header)
// or HTML (with zerverg:* meta tags), exactly as a file upload would.
"use strict";

(function () {
  const { el, api } = ZV;

  // ---------------------------------------------------------------
  // source <-> fields
  // ---------------------------------------------------------------

  const fieldKeys = ["title", "date", "tags", "kind", "layout"];

  /// Splits a stored entry into fields and body text.
  function parseSource(text, format) {
    return format === "markdown" ? parseMarkdown(text) : parseHtml(text);
  }

  function parseMarkdown(text) {
    const entry = { body: text, extra: [] };
    const match = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*(\r?\n|$)/.exec(text);
    if (!match) return entry;
    entry.body = text.slice(match[0].length).replace(/^\r?\n/, "");
    for (const line of match[1].split(/\r?\n/)) {
      const colon = line.indexOf(":");
      const key = colon < 0 ? "" : line.slice(0, colon).trim();
      if (fieldKeys.includes(key)) {
        entry[key] = line.slice(colon + 1).trim().replace(/^(["'[])(.*)["'\]]$/, "$2");
      } else if (key !== "slug" && line.trim()) entry.extra.push(line);
    }
    return entry;
  }

  function parseHtml(text) {
    const doc = new DOMParser().parseFromString(text, "text/html");
    const entry = { extra: [] };
    for (const meta of doc.querySelectorAll("meta[name^='zerverg:']")) {
      const key = meta.getAttribute("name").slice("zerverg:".length);
      if (fieldKeys.includes(key)) entry[key] = meta.getAttribute("content") || "";
    }
    if (!entry.title) entry.title = (doc.title || "").trim();
    // Keep the body text exactly as written, not re-serialised.
    const open = /<body[^>]*>/i.exec(text);
    const close = text.search(/<\/body>/i);
    entry.body = open ? text.slice(open.index + open[0].length,
      close > open.index ? close : undefined).replace(/^\r?\n/, "").replace(/\s+$/, "\n")
      : text;
    return entry;
  }

  /// Builds the file to store from the fields and body.
  function composeSource(entry, format) {
    return format === "markdown" ? composeMarkdown(entry) : composeHtml(entry);
  }

  function composeMarkdown(entry) {
    const lines = ["---"];
    for (const key of fieldKeys) {
      const value = (entry[key] || "").trim();
      if (!value || (key === "kind" && value === "post")) continue;
      lines.push(key + ": " + value);
    }
    lines.push(...entry.extra, "---", "", entry.body);
    return lines.join("\n");
  }

  function attr(value) {
    return value.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;");
  }

  function composeHtml(entry) {
    const head = ["<!doctype html>", "<html>", "<head>",
      "<title>" + (entry.title || "").replace(/</g, "") + "</title>"];
    for (const key of ["date", "kind", "tags", "layout"]) {
      const value = (entry[key] || "").trim();
      if (!value || (key === "kind" && value === "post")) continue;
      head.push("<meta name=\"zerverg:" + key + "\" content=\"" + attr(value) + "\">");
    }
    return head.concat(["</head>", "<body>", "", entry.body.replace(/\s+$/, ""),
      "", "</body>", "</html>", ""]).join("\n");
  }

  // ---------------------------------------------------------------
  // formatting toolbar
  // ---------------------------------------------------------------

  /// [label, title, markdown action, html action]
  const tools = [
    ["B", "Bold", (a) => ZV.wrapSelection(a, "**", "**", "bold text"),
      (a) => ZV.wrapSelection(a, "<strong>", "</strong>", "bold text")],
    ["I", "Italic", (a) => ZV.wrapSelection(a, "*", "*", "italic text"),
      (a) => ZV.wrapSelection(a, "<em>", "</em>", "italic text")],
    ["H2", "Heading", (a) => ZV.prefixLines(a, "## "),
      (a) => ZV.wrapSelection(a, "<h2>", "</h2>", "Heading")],
    ["H3", "Subheading", (a) => ZV.prefixLines(a, "### "),
      (a) => ZV.wrapSelection(a, "<h3>", "</h3>", "Subheading")],
    null,
    ["Link", "Link", (a) => ZV.wrapSelection(a, "[", "](https://)", "link text"),
      (a) => ZV.wrapSelection(a, "<a href=\"https://\">", "</a>", "link text")],
    ["Quote", "Quote", (a) => ZV.prefixLines(a, "> "),
      (a) => ZV.wrapSelection(a, "<blockquote>\n", "\n</blockquote>", "Quote")],
    ["• List", "Bulleted list", (a) => ZV.prefixLines(a, "- "),
      (a) => ZV.wrapSelection(a, "<ul>\n  <li>", "</li>\n</ul>", "item")],
    ["1. List", "Numbered list", (a) => ZV.prefixLines(a, "1. "),
      (a) => ZV.wrapSelection(a, "<ol>\n  <li>", "</li>\n</ol>", "item")],
    ["Code", "Code", (a) => ZV.wrapSelection(a, "`", "`", "code"),
      (a) => ZV.wrapSelection(a, "<code>", "</code>", "code")],
    ["Block", "Styled block (::: name)",
      (a) => ZV.wrapSelection(a, "\n::: note\n", "\n:::\n", "Text in a styled block."),
      (a) => ZV.wrapSelection(a, "<div class=\"note\">\n", "\n</div>", "Text in a styled block.")],
    ["―", "Divider", (a) => ZV.insertText(a, "\n\n---\n\n"),
      (a) => ZV.insertText(a, "\n<hr>\n")],
  ];

  function formatBar(state, area, onImage) {
    const bar = el("div", { class: "format-bar", role: "toolbar",
      "aria-label": "Formatting" });
    for (const tool of tools) {
      if (!tool) {
        bar.append(el("span", { class: "sep", "aria-hidden": "true" }));
        continue;
      }
      const [label, title, md, html] = tool;
      bar.append(ZV.button(label, () => (state.format === "markdown" ? md : html)(area),
        "ghost", { title, "aria-label": title }));
    }
    bar.append(el("span", { class: "sep", "aria-hidden": "true" }),
      ZV.button("Image", onImage, "ghost", { title: "Upload and insert an image" }));
    return bar;
  }

  // ---------------------------------------------------------------
  // media in the text
  // ---------------------------------------------------------------

  function mediaSnippet(name, format) {
    const alt = name.replace(/\.[^.]+$/, "").replace(/[-_]+/g, " ");
    if (ZV.isVideo(name)) {
      return "\n<video src=\"media:" + name + "\" controls></video>\n";
    }
    return format === "markdown" ? "![" + alt + "](media:" + name + ")"
      : "<img src=\"media:" + name + "\" alt=\"" + alt + "\">";
  }

  async function insertMedia(state, area, files) {
    for (const file of files) {
      if (!ZV.isImage(file.name) && !ZV.isVideo(file.name)) {
        ZV.toast("\"" + file.name + "\" isn't an image or video.", "error");
        continue;
      }
      try {
        const name = await ZV.uploadMedia(file, state.media);
        ZV.insertText(area, mediaSnippet(name, state.format));
      } catch (err) {
        ZV.toast(file.name + ": " + err.message, "error");
      }
    }
  }

  function acceptFiles(state, area) {
    area.addEventListener("dragover", (e) => {
      if (!e.dataTransfer.types.includes("Files")) return;
      e.preventDefault();
      area.classList.add("dragging");
    });
    area.addEventListener("dragleave", () => area.classList.remove("dragging"));
    area.addEventListener("drop", (e) => {
      area.classList.remove("dragging");
      if (!e.dataTransfer.files.length) return;
      e.preventDefault();
      insertMedia(state, area, [...e.dataTransfer.files]);
    });
    area.addEventListener("paste", (e) => {
      const files = [...e.clipboardData.files];
      if (!files.length) return;
      e.preventDefault();
      insertMedia(state, area, files);
    });
  }

  // ---------------------------------------------------------------
  // preview
  // ---------------------------------------------------------------

  /// Server-rendered preview in a sandboxed frame (no scripts run).
  function previewPane(getSource) {
    const frame = el("iframe", { title: "Preview", sandbox: "allow-same-origin" });
    const note = el("span", { class: "hint", text: "Updates as you type" });
    let timer = null, seq = 0;
    const update = async () => {
      const mine = ++seq;
      const { text, format } = getSource();
      try {
        const html = await api("POST", "/preview", text, { format });
        if (mine !== seq) return;
        const scroll = frame.contentWindow ? frame.contentWindow.scrollY : 0;
        frame.addEventListener("load", () => frame.contentWindow.scrollTo(0, scroll),
          { once: true });
        frame.srcdoc = html;
        note.textContent = "Updates as you type";
      } catch (err) {
        if (mine === seq) note.textContent = err.message;
      }
    };
    const pane = el("div", { class: "card preview-pane", "aria-label": "Preview" }, [
      el("div", { class: "editor-head" }, [el("strong", { text: "Preview" }),
        el("span", { class: "spacer" }), note]),
      frame,
    ]);
    pane.schedule = () => {
      clearTimeout(timer);
      timer = setTimeout(update, 450);
    };
    pane.now = update;
    return pane;
  }

  // ---------------------------------------------------------------
  // the view
  // ---------------------------------------------------------------

  const today = () => new Date(Date.now() - new Date().getTimezoneOffset() * 60000)
    .toISOString().slice(0, 10);

  function preferredFormat() {
    try { return localStorage.getItem("zv-format") || "markdown"; } catch (_) { return "markdown"; }
  }

  function rememberFormat(format) {
    try { localStorage.setItem("zv-format", format); } catch (_) { /* private mode */ }
  }

  /// `#/write` (new) or `#/write/<slug>`
  ZV.views.write = async function writeView(slug) {
    let entries, layouts, media, text = "";
    try {
      [entries, layouts, media] = await Promise.all(
        ["/posts", "/layouts", "/media"].map((p) => api("GET", p)));
      if (slug) text = await api("GET", "/posts/" + encodeURIComponent(slug));
    } catch (err) {
      return ZV.failed(err);
    }
    const existing = slug ? entries.find((e) => e.slug === slug) : null;
    const format = existing ? existing.format : preferredFormat();
    const entry = slug ? parseSource(text, format)
      : { title: "", date: today(), tags: "", kind: "post", layout: "", body: "", extra: [] };
    buildEditor({
      slug: slug || "",
      isNew: !slug,
      format,
      entry,
      slugs: new Set(entries.map((e) => e.slug)),
      layouts,
      media: new Set(media.map((m) => m.name)),
    });
  };

  function buildEditor(state) {
    const ui = editorControls(state);
    const compose = () => composeSource(readFields(ui, state), state.format);
    // A new entry counts as changed once it differs from the blank form.
    let saved = compose();
    const dirty = () => compose() !== saved;
    const preview = previewPane(() => {
      const fields = readFields(ui, state);
      fields.title = fields.title || "Untitled";
      return { text: composeSource(fields, state.format), format: state.format };
    });
    const refresh = () => {
      if (state.isNew) ui.status.set(true, "Not saved yet");
      else ui.status.set(dirty());
      ui.viewLink.hidden = state.isNew;
      preview.schedule();
    };
    const save = ZV.button("Save", async () => {
      if (!(await ZV.busy(save, saveEntry(state, ui, compose)))) return;
      saved = compose();
      refresh();
    }, "primary");
    ui.onChange = refresh;
    ZV.editorKeys(ui.area, () => save.click());
    ui.title.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        save.click();
      }
    });
    ZV.unsaved = dirty;
    ZV.show(layoutWrite(state, ui, preview, save));
    acceptFiles(state, ui.area);
    refresh();
    preview.now();
    (state.isNew ? ui.title : ui.area).focus({ preventScroll: true });
  }

  function readFields(ui, state) {
    return {
      title: ui.title.value.trim(),
      date: ui.date.value,
      tags: ui.tags.value.trim(),
      kind: ui.kind.value,
      layout: ui.layout.value,
      body: ui.area.value,
      extra: state.entry.extra,
    };
  }

  function editorControls(state) {
    const e = state.entry;
    const ui = { onChange: () => {} };
    const changed = () => ui.onChange();
    ui.title = el("input", { type: "text", class: "title-input", placeholder: "Title",
      "aria-label": "Title", value: e.title || "", on: { input: () => {
        if (state.isNew && !ui.slugEdited) ui.slug.value = ZV.slugify(ui.title.value);
        changed();
      } } });
    ui.date = el("input", { type: "date", value: e.date || "", on: { input: changed } });
    ui.tags = el("input", { type: "text", value: e.tags || "", placeholder: "travel, recipes",
      on: { input: changed } });
    ui.kind = el("select", { on: { change: changed } }, [
      el("option", { value: "post", text: "Post (dated, listed)", selected: e.kind !== "page" }),
      el("option", { value: "page", text: "Page (standalone)", selected: e.kind === "page" }),
    ]);
    ui.layout = el("select", { on: { change: changed } }, [
      el("option", { value: "", text: "Site default" })].concat(state.layouts.map((l) =>
      el("option", { value: l.name, text: l.name, selected: l.name === e.layout }))));
    ui.slug = el("input", { type: "text", class: "mono", value: state.slug,
      readonly: !state.isNew, on: { input: () => { ui.slugEdited = true; } } });
    ui.area = el("textarea", { class: "text-area", spellcheck: "true",
      "aria-label": "Text", placeholder: "Start writing…", on: { input: changed } });
    ui.area.value = e.body || "";
    ui.status = ZV.statusBadge();
    ui.viewLink = ZV.link("View ↗", ZV.siteUrl(state.slug), "ghost",
      { target: "_blank", rel: "noopener" });
    ui.formats = formatSwitch(state, ui, changed);
    return ui;
  }

  function formatSwitch(state, ui, changed) {
    const box = el("div", { class: "segmented", role: "group", "aria-label": "Format" });
    const sync = () => {
      for (const b of box.children) {
        b.setAttribute("aria-pressed", String(b.value === state.format));
      }
      ui.area.classList.toggle("mono", state.format === "html");
    };
    for (const [value, label] of [["markdown", "Markdown"], ["html", "HTML"]]) {
      box.append(el("button", { type: "button", value, text: label, on: { click: () => {
        if (state.format === value) return;
        state.format = value;
        rememberFormat(value);
        sync();
        changed();
      } } }));
    }
    sync();
    return box;
  }

  function layoutWrite(state, ui, preview, save) {
    const details = el("details", { class: "more" }, [
      el("summary", { text: "More options" }),
      el("div", { class: "form-grid" }, [
        ZV.field("Address", ui.slug, state.isNew
          ? "The entry's URL path. Filled in from the title; " +
            "letters, digits, - and _."
          : "Fixed after the first save."),
        ZV.field("Layout", ui.layout, "Leave on the site default unless " +
          "this entry needs its own."),
      ]),
    ]);
    const editPane = el("div", { class: "edit-pane" }, [
      ui.title,
      el("div", { class: "meta-grid" }, [
        ZV.field("Date", ui.date), ZV.field("Tags", ui.tags, "Separate with commas."),
        ZV.field("Type", ui.kind),
      ]),
      details,
      el("div", { class: "card" }, [
        formatBar(state, ui.area, async () => {
          const files = await ZV.pickFiles("image/*,video/mp4,video/webm,video/ogg", true);
          insertMedia(state, ui.area, files);
        }),
        ui.area,
      ]),
      cheatsheet(),
    ]);
    const grid = el("div", { class: "write editing" }, [editPane, preview]);
    return ZV.page({
      title: state.isNew ? "New post" : "Edit",
      back: { href: "#/posts", label: "Posts & pages" },
      actions: [ui.status, paneSwitch(grid), previewToggle(grid), ui.formats,
        ui.viewLink, save],
      wide: true,
    }, [grid]);
  }

  /// Small screens: switch between writing and preview.
  function paneSwitch(grid) {
    const box = el("div", { class: "segmented pane-switch", role: "group",
      "aria-label": "Show" });
    for (const [mode, label] of [["editing", "Write"], ["previewing", "Preview"]]) {
      box.append(el("button", { type: "button", "aria-pressed": String(mode === "editing"),
        text: label, on: { click: (e) => {
          grid.classList.remove("editing", "previewing");
          grid.classList.add(mode);
          for (const b of box.children) b.setAttribute("aria-pressed", "false");
          e.target.setAttribute("aria-pressed", "true");
        } } }));
    }
    return box;
  }

  /// Wide screens: hide or show the preview column.
  function previewToggle(grid) {
    let hidden = false;
    try { hidden = localStorage.getItem("zv-preview") === "off"; } catch (_) { /* ignore */ }
    const button = ZV.button("", () => {
      hidden = !hidden;
      try { localStorage.setItem("zv-preview", hidden ? "off" : "on"); } catch (_) { /* ignore */ }
      sync();
    }, "ghost pane-toggle");
    const sync = () => {
      grid.classList.toggle("no-preview", hidden);
      button.textContent = hidden ? "Show preview" : "Hide preview";
    };
    sync();
    return button;
  }

  function cheatsheet() {
    const rows = [
      ["**bold**  *italic*", "emphasis"],
      ["# Title  ## Section", "headings"],
      ["[text](https://…)", "a link"],
      ["![description](media:photo.jpg)", "an image from Media"],
      ["- item  /  1. item", "lists"],
      ["> text", "a quote"],
      ["| a | b |  then  |---|---|", "a table"],
      ["::: note … :::", "a block the stylesheet styles as .note"],
      ["<any html>", "raw HTML, when you need it"],
    ];
    return el("details", { class: "more" }, [
      el("summary", { text: "Markdown cheat sheet" }),
      el("dl", { class: "cheatsheet" }, rows.flatMap(([code, what]) =>
        [el("dt", { text: code }), el("dd", { text: what })])),
    ]);
  }

  // ---------------------------------------------------------------
  // saving
  // ---------------------------------------------------------------

  async function saveEntry(state, ui, compose) {
    const slug = ui.slug.value.trim();
    const problem = ZV.checkSlug(slug);
    if (problem) {
      ui.slug.closest("details").open = true;
      ui.slug.setAttribute("aria-invalid", "true");
      ui.slug.focus();
      ZV.toast(problem, "error");
      return false;
    }
    ui.slug.removeAttribute("aria-invalid");
    if (state.isNew && state.slugs.has(slug) && !(await ZV.confirm({
      title: "Replace /" + slug + "?",
      message: "Another entry already uses this address. Saving replaces it.",
      action: "Replace",
      danger: true,
    }))) return false;
    try {
      const format = state.format === "markdown" ? "md" : "html";
      await api("PUT", "/posts/" + slug, compose(), { format });
    } catch (err) {
      ZV.failed(err);
      return false;
    }
    ZV.toast(state.isNew ? "Published at /" + slug + "." : "Saved.");
    if (state.isNew) {
      state.isNew = false;
      state.slug = slug;
      state.slugs.add(slug);
      ui.slug.readOnly = true;
      ui.viewLink.href = ZV.siteUrl(slug);
      history.replaceState(null, "", "#/write/" + encodeURIComponent(slug));
    }
    return true;
  }
})();
