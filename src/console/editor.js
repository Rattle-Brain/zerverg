// zerverg console: text editing helpers and the code editor for
// layouts, styles and snippets (every save is a new version).
"use strict";

(function () {
  const { el, api } = ZV;

  // ---------------------------------------------------------------
  // textarea helpers
  // ---------------------------------------------------------------

  /// Replaces the selection, keeping the browser's undo history.
  ZV.insertText = function (area, text, selectFrom, selectTo) {
    area.focus();
    const start = area.selectionStart;
    if (!document.execCommand("insertText", false, text)) {
      area.setRangeText(text, start, area.selectionEnd, "end");
      area.dispatchEvent(new Event("input", { bubbles: true }));
    }
    if (selectFrom != null) {
      area.setSelectionRange(start + selectFrom, start + (selectTo ?? selectFrom));
    }
  };

  /// Wraps the selection (or `placeholder`) in `before` / `after`.
  ZV.wrapSelection = function (area, before, after, placeholder) {
    const selected = area.value.slice(area.selectionStart, area.selectionEnd);
    const inner = selected || placeholder || "";
    ZV.insertText(area, before + inner + after, before.length, before.length + inner.length);
  };

  /// Prefixes every selected line (`## `, `> `, `- `).
  ZV.prefixLines = function (area, prefix) {
    const value = area.value;
    const start = lineStart(value, area.selectionStart);
    let end = value.indexOf("\n", area.selectionEnd);
    if (end < 0) end = value.length;
    area.setSelectionRange(start, end);
    const lines = value.slice(start, end).split("\n");
    const numbered = prefix === "1. ";
    const text = lines.map((l, i) => (numbered ? i + 1 + ". " : prefix) + l).join("\n");
    ZV.insertText(area, text, text.length);
  };

  /// Tab indents, Shift+Tab unindents, Ctrl/Cmd+S saves.
  ZV.editorKeys = function (area, onSave) {
    area.addEventListener("keydown", (e) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
        e.preventDefault();
        onSave();
      } else if (e.key === "Tab" && !e.altKey && !e.ctrlKey && !e.metaKey) {
        e.preventDefault();
        if (e.shiftKey) unindent(area);
        else ZV.insertText(area, "  ");
      }
    });
  };

  function lineStart(value, pos) {
    return pos === 0 ? 0 : value.lastIndexOf("\n", pos - 1) + 1;
  }

  function unindent(area) {
    const value = area.value;
    const start = lineStart(value, area.selectionStart);
    if (value.startsWith("  ", start)) {
      area.setSelectionRange(start, start + 2);
      ZV.insertText(area, "");
    }
  }

  /// "Saved" / "Unsaved changes" indicator.
  ZV.statusBadge = function () {
    const node = el("span", { class: "status", role: "status" });
    node.set = (dirty, text) => {
      node.classList.toggle("dirty", dirty);
      node.textContent = text || (dirty ? "Unsaved changes" : "Saved");
    };
    return node;
  };

  // ---------------------------------------------------------------
  // layouts, styles, snippets
  // ---------------------------------------------------------------

  const starters = {
    styles: "/* A new stylesheet. Activate it under Styles or Site. */\n\n" +
      "body {\n  max-width: 42rem;\n  margin: 0 auto;\n  padding: 2rem 1rem;\n" +
      "  font: 18px/1.7 Georgia, serif;\n}\n",
    snippets: "// Runs on every page while enabled.\n" +
      "document.addEventListener(\"DOMContentLoaded\", () => {\n});\n",
  };

  /// `#/edit/<kind>/<name>[/new]`
  ZV.views.edit = async function editView(kind, name, isNew) {
    const info = ZV.kinds[kind];
    if (!info || !name) return ZV.go("#/posts");
    let text = "", site, versions = [];
    try {
      site = await api("GET", "/site");
      if (isNew) text = await starterFor(kind, site);
      else {
        [text, versions] = await Promise.all([
          api("GET", "/" + kind + "/" + name),
          api("GET", "/" + kind + "/" + name + "/versions"),
        ]);
      }
    } catch (err) {
      return ZV.failed(err);
    }
    renderEditor({ kind, name, info, site, text, versions, isNew: Boolean(isNew) });
  };

  /// New layouts start as a copy of the active one, so they validate.
  async function starterFor(kind, site) {
    if (kind !== "layouts") return starters[kind] || "";
    if (!site.active_layout) return "<layout>\n  <main/>\n</layout>\n";
    return api("GET", "/layouts/" + site.active_layout);
  }

  function renderEditor(state) {
    const { kind, name, info, site } = state;
    let saved = state.isNew ? null : state.text;
    const area = el("textarea", { class: "code-area", spellcheck: "false",
      "aria-label": info.noun + " source", autocapitalize: "off" });
    area.value = state.text;
    const status = ZV.statusBadge();
    const dirty = () => area.value !== saved;
    const refresh = () => status.set(dirty(), saved === null ? "Not saved yet" : "");
    const save = ZV.button("Save", () => doSave(), "primary");
    const historyBox = el("div", { class: "card", hidden: true });

    async function doSave() {
      try {
        const res = await ZV.busy(save, api("PUT", "/" + kind + "/" + name, area.value));
        saved = area.value;
        refresh();
        ZV.toast("Saved \"" + name + "\" as version " + res.version + ".");
        if (state.isNew) {
          state.isNew = false;
          history.replaceState(null, "", "#/edit/" + kind + "/" + encodeURIComponent(name));
        }
        state.versions = await api("GET", "/" + kind + "/" + name + "/versions");
        if (!historyBox.hidden) showHistory(state, area, historyBox);
      } catch (err) {
        ZV.failed(err);
      }
    }

    area.addEventListener("input", refresh);
    ZV.editorKeys(area, doSave);
    ZV.unsaved = dirty;
    refresh();
    const active = ZV.isActive(kind, name, site);
    ZV.show(ZV.page({
      title: name,
      back: { href: "#/" + kind, label: info.title },
      lead: active ? "In use on the live site: saving changes it immediately."
        : "Not in use. Saving won't change the live site.",
      actions: [
        ZV.button("History", () => {
          historyBox.hidden = !historyBox.hidden;
          if (!historyBox.hidden) showHistory(state, area, historyBox);
        }),
        ZV.link("View site ↗", ZV.siteUrl(""), "ghost", { target: "_blank", rel: "noopener" }),
        save,
      ],
      wide: true,
    }, [
      historyBox,
      el("div", { class: "card" }, [
        el("div", { class: "editor-head" }, [
          status, el("span", { class: "spacer" }),
          el("span", {}, [el("kbd", { text: "Ctrl" }), " + ", el("kbd", { text: "S" }), " saves"]),
        ]),
        area,
      ]),
    ]));
    area.focus({ preventScroll: true });
  }

  function showHistory(state, area, box) {
    const { kind, name } = state;
    const rows = state.versions.slice().reverse().map((v, i) => el("li", { class: "list-row" }, [
      el("div", { class: "main" }, [
        el("span", { class: "title", text: "Version " + v }),
        el("div", { class: "sub", text: i === 0 ? "current" : "" }),
      ]),
      el("div", { class: "actions" }, [
        ZV.button("Load into editor", async () => {
          try {
            area.value = await api("GET", "/" + kind + "/" + name, undefined, { version: v });
            area.dispatchEvent(new Event("input"));
            ZV.toast("Loaded version " + v + ". Save to make it current.");
          } catch (err) {
            ZV.failed(err);
          }
        }, "small"),
      ]),
    ]));
    box.replaceChildren(el("div", { class: "card-body" }, [
      el("h2", { text: "Version history" }),
      el("p", { class: "hint", text: "Older versions are kept. Load one, " +
        "check it, and save to bring it back." }),
    ]), rows.length ? el("ul", { class: "list" }, rows) : null);
  }
})();
