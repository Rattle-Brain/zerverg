// zerverg console views: posts, media, layouts / styles / snippets
// lists, and site settings. Editors live in editor.js and write.js.
"use strict";

(function () {
  const { el, api } = ZV;

  // ---------------------------------------------------------------
  // file picking and uploads
  // ---------------------------------------------------------------

  /// Opens the system file picker; resolves with the chosen files.
  ZV.pickFiles = function (accept, multiple) {
    return new Promise((resolve) => {
      const input = el("input", { type: "file", accept, multiple: Boolean(multiple) });
      input.addEventListener("change", () => resolve([...input.files]));
      input.click();
    });
  };

  /// A drop area that also opens the picker on click.
  ZV.dropzone = function (text, accept, onFiles) {
    const choose = ZV.button("Choose files", async () => {
      const files = await ZV.pickFiles(accept, true);
      if (files.length) onFiles(files);
    });
    const zone = el("div", { class: "dropzone" }, [
      el("strong", { text }), el("span", { text: "Drag files here, or" }), choose,
    ]);
    zone.addEventListener("dragover", (e) => { e.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (e) => {
      e.preventDefault();
      zone.classList.remove("over");
      if (e.dataTransfer.files.length) onFiles([...e.dataTransfer.files]);
    });
    return zone;
  };

  ZV.isImage = (name) => /\.(png|jpe?g|gif|webp|avif|svg|ico)$/i.test(name);
  ZV.isVideo = (name) => /\.(mp4|webm|ogv)$/i.test(name);

  /// Uploads one media file under a free name; resolves with it.
  ZV.uploadMedia = async function (file, taken) {
    let name = ZV.mediaName(file.name);
    if (taken && taken.has(name)) {
      const dot = name.lastIndexOf(".");
      name = name.slice(0, dot) + "-" + Date.now().toString(36) + name.slice(dot);
    }
    await api("PUT", "/media/" + name, file);
    if (taken) taken.add(name);
    return name;
  };

  ZV.copy = async function (text, what) {
    try {
      await navigator.clipboard.writeText(text);
      ZV.toast("Copied " + what + ".");
    } catch (_) {
      ZV.toast("Copy this: " + text);
    }
  };

  // ---------------------------------------------------------------
  // posts and pages
  // ---------------------------------------------------------------

  const formatLabel = { markdown: "Markdown", html: "HTML" };

  ZV.views.posts = async function postsView() {
    let entries;
    try {
      entries = await api("GET", "/posts");
    } catch (err) {
      return ZV.failed(err);
    }
    const listBox = el("div");
    const search = el("input", { type: "search", placeholder: "Search titles and tags",
      "aria-label": "Search posts" });
    let kind = "all";
    const kinds = segmented(["all", "post", "page"], ["All", "Posts", "Pages"], (k) => {
      kind = k;
      render();
    });
    const render = () => listBox.replaceChildren(postList(entries, search.value, kind));
    search.addEventListener("input", render);
    render();
    ZV.show(ZV.page({
      title: "Posts & pages",
      lead: "Everything on your site. A page named \"index\" becomes your home page.",
      actions: [
        ZV.button("Upload files", () => uploadEntries(entries)),
        ZV.link("New post", "#/write", "primary"),
      ],
    }, [el("div", { class: "toolbar" }, [search, kinds]), listBox]));
  };

  function segmented(values, labels, onPick) {
    const box = el("div", { class: "segmented", role: "group" });
    values.forEach((value, i) => {
      const b = el("button", { type: "button", "aria-pressed": i === 0 ? "true" : "false",
        text: labels[i], on: { click: () => {
          for (const other of box.children) other.setAttribute("aria-pressed", "false");
          b.setAttribute("aria-pressed", "true");
          onPick(value);
        } } });
      box.append(b);
    });
    return box;
  }

  function postList(entries, query, kind) {
    const q = query.trim().toLowerCase();
    const shown = entries.filter((e) => (kind === "all" || e.meta.kind === kind) &&
      (!q || (e.meta.title + " " + e.slug + " " + e.meta.tags).toLowerCase().includes(q)));
    if (!entries.length) {
      return el("div", { class: "card" }, ZV.empty("No posts yet",
        "Write your first post; it appears on the site as soon as you save it.",
        ZV.link("Write a post", "#/write", "primary")));
    }
    if (!shown.length) {
      return el("div", { class: "card" }, ZV.empty("Nothing matches",
        "Try a different search or filter."));
    }
    return el("ul", { class: "card list" }, shown.map(postRow));
  }

  function postRow(entry) {
    const meta = entry.meta;
    const editHref = "#/write/" + encodeURIComponent(entry.slug);
    const sub = [
      el("span", { class: "mono", text: "/" + entry.slug }),
      meta.date ? el("span", { text: meta.date }) : null,
      meta.tags ? el("span", { text: meta.tags }) : null,
    ];
    return el("li", { class: "list-row" }, [
      el("div", { class: "main" }, [
        el("a", { class: "title", href: editHref, text: meta.title || entry.slug }),
        el("div", { class: "sub" }, sub),
      ]),
      el("span", { class: meta.kind === "page" ? "badge accent" : "badge", text: meta.kind }),
      el("span", { class: "badge", text: formatLabel[entry.format] || entry.format }),
      el("div", { class: "actions" }, [
        ZV.link("Edit", editHref, "small"),
        ZV.link("View ↗", ZV.siteUrl(entry.slug), "small ghost",
          { target: "_blank", rel: "noopener" }),
        ZV.button("Delete", () => ZV.remove("\"" + (meta.title || entry.slug) + "\"",
          "/posts/" + entry.slug, ZV.views.posts), "small ghost danger"),
      ]),
    ]);
  }

  async function uploadEntries(entries) {
    const files = await ZV.pickFiles(".html,.htm,.md,.markdown,text/html,text/markdown", true);
    const existing = new Set(entries.map((e) => e.slug));
    for (const file of files) {
      const slug = ZV.slugify(file.name);
      if (ZV.checkSlug(slug)) {
        ZV.toast("Skipped \"" + file.name + "\": can't make a valid name from it.", "error");
        continue;
      }
      if (existing.has(slug) && !(await ZV.confirm({
        title: "Replace \"" + slug + "\"?",
        message: "An entry with this name exists. Uploading replaces it.",
        action: "Replace",
      }))) continue;
      const format = /\.(md|markdown)$/i.test(file.name) ? "md" : "html";
      try {
        await api("PUT", "/posts/" + slug, file, { format });
        ZV.toast("Uploaded \"" + slug + "\".");
      } catch (err) {
        ZV.toast(file.name + ": " + err.message, "error");
      }
    }
    if (files.length) ZV.views.posts();
  }

  // ---------------------------------------------------------------
  // layouts, styles, snippets
  // ---------------------------------------------------------------

  ZV.kinds = {
    styles: {
      title: "Styles", noun: "stylesheet", ext: ".css",
      lead: "Stylesheets decide how every page looks. One is active at a " +
        "time. Duplicate one to experiment without touching the live site.",
    },
    layouts: {
      title: "Layouts", noun: "layout", ext: ".xml",
      lead: "Layouts arrange each page: header, navigation, content and " +
        "sidebars. They are XML; see /docs on your site for the elements.",
    },
    snippets: {
      title: "Snippets", noun: "snippet", ext: ".js",
      lead: "Small scripts added to every page while enabled. Only " +
        "enable code you trust: it runs with full page access.",
    },
  };

  ZV.isActive = function (kind, name, site) {
    if (kind === "layouts") return site.active_layout === name;
    if (kind === "styles") return site.active_style === name;
    return site.enabled_snippets.includes(name);
  };

  ZV.saveSite = async function (site) {
    await api("PUT", "/site", site);
    ZV.toast("Site settings saved.");
  };

  /// Makes `name` active (layouts, styles) or toggles it (snippets).
  ZV.toggleActive = async function (kind, name, site) {
    const next = Object.assign({}, site);
    if (kind === "layouts") next.active_layout = name;
    else if (kind === "styles") next.active_style = name;
    else if (site.enabled_snippets.includes(name)) {
      next.enabled_snippets = site.enabled_snippets.filter((n) => n !== name);
    } else next.enabled_snippets = site.enabled_snippets.concat([name]);
    await ZV.saveSite(next);
  };

  function libraryView(kind) {
    return async function view() {
      let items, site;
      try {
        [items, site] = await Promise.all([api("GET", "/" + kind), api("GET", "/site")]);
      } catch (err) {
        return ZV.failed(err);
      }
      const info = ZV.kinds[kind];
      const rows = items.map((item) => libraryRow(kind, item, site));
      const body = items.length ? el("ul", { class: "card list" }, rows)
        : el("div", { class: "card" }, ZV.empty("No " + info.noun + "s yet",
          "Create one here or upload a " + info.ext + " file."));
      ZV.show(ZV.page({
        title: info.title,
        lead: info.lead,
        actions: [
          ZV.button("Upload file", () => uploadLibrary(kind)),
          ZV.button("New " + info.noun, () => createItem(kind), "primary"),
        ],
      }, [body]));
    };
  }

  function libraryRow(kind, item, site) {
    const active = ZV.isActive(kind, item.name, site);
    const editHref = "#/edit/" + kind + "/" + encodeURIComponent(item.name);
    const reload = () => ZV.views[kind]();
    const toggleLabel = kind === "snippets" ? (active ? "Disable" : "Enable") : "Use this";
    const toggle = kind !== "snippets" && active ? null
      : ZV.button(toggleLabel, () => ZV.toggleActive(kind, item.name, site)
        .then(reload, ZV.failed), "small");
    return el("li", { class: "list-row" }, [
      el("div", { class: "main" }, [
        el("a", { class: "title mono", href: editHref, text: item.name }),
        el("div", { class: "sub" }, [el("span", { text: "version " + item.version })]),
      ]),
      active ? el("span", { class: "badge on",
        text: kind === "snippets" ? "enabled" : "in use" }) : null,
      el("div", { class: "actions" }, [
        ZV.link("Edit", editHref, "small"),
        toggle,
        ZV.button("Duplicate", () => duplicate(kind, item.name), "small ghost"),
        ZV.button("Delete", () => ZV.remove(ZV.kinds[kind].noun + " \"" + item.name +
          "\" and all its versions", "/" + kind + "/" + item.name, reload),
          "small ghost danger"),
      ]),
    ]);
  }

  async function askName(kind, title, value) {
    return ZV.prompt({
      title,
      label: "Name",
      value,
      hint: "Lowercase letters, digits, - and _.",
      action: "Create",
      check: ZV.checkSlug,
    });
  }

  async function createItem(kind) {
    const name = await askName(kind, "New " + ZV.kinds[kind].noun, "");
    if (name) ZV.go("#/edit/" + kind + "/" + encodeURIComponent(name) + "/new");
  }

  async function duplicate(kind, name) {
    const copy = await askName(kind, "Duplicate \"" + name + "\"", name + "-copy");
    if (!copy) return;
    try {
      const text = await api("GET", "/" + kind + "/" + name);
      await api("PUT", "/" + kind + "/" + copy, text);
      ZV.toast("Created \"" + copy + "\".");
      ZV.go("#/edit/" + kind + "/" + encodeURIComponent(copy));
    } catch (err) {
      ZV.failed(err);
    }
  }

  async function uploadLibrary(kind) {
    const info = ZV.kinds[kind];
    const [file] = await ZV.pickFiles(info.ext);
    if (!file) return;
    const name = await askName(kind, "Upload " + info.noun, ZV.slugify(file.name));
    if (!name) return;
    try {
      const res = await api("PUT", "/" + kind + "/" + name, file);
      ZV.toast("Uploaded \"" + name + "\" as version " + res.version + ".");
      ZV.views[kind]();
    } catch (err) {
      ZV.failed(err);
    }
  }

  for (const kind of Object.keys(ZV.kinds)) ZV.views[kind] = libraryView(kind);

  // ---------------------------------------------------------------
  // media
  // ---------------------------------------------------------------

  const mediaAccept = ".png,.jpg,.jpeg,.gif,.webp,.avif,.svg,.ico,.mp4,.webm,.ogv";

  ZV.views.media = async function mediaView() {
    let items;
    try {
      items = await api("GET", "/media");
    } catch (err) {
      return ZV.failed(err);
    }
    const taken = new Set(items.map((i) => i.name));
    const upload = async (files) => {
      for (const file of files) {
        try {
          const name = await ZV.uploadMedia(file, taken);
          ZV.toast("Uploaded \"" + name + "\".");
        } catch (err) {
          ZV.toast(file.name + ": " + err.message, "error");
        }
      }
      ZV.views.media();
    };
    const grid = items.length ? el("div", { class: "media-grid" }, items.map(mediaCard))
      : el("div", { class: "card" }, ZV.empty("No media yet",
        "Uploaded images and videos show up here."));
    ZV.show(ZV.page({
      title: "Media",
      lead: ["Images and videos for your posts. In Markdown write ",
        el("code", { text: "![description](media:photo.jpg)" }),
        "; the Write view's Image button does it for you."],
    }, [ZV.dropzone("Upload images or videos", mediaAccept, upload), grid]));
  };

  function mediaCard(item) {
    const src = "/media/" + item.name;
    const preview = ZV.isImage(item.name) ? el("img", { src, alt: "", loading: "lazy" })
      : ZV.isVideo(item.name) ? el("video", { src, muted: true, preload: "metadata" })
        : el("span", { text: item.content_type });
    return el("div", { class: "card media-card" }, [
      el("div", { class: "thumb" }, preview),
      el("div", { class: "meta" }, [
        el("div", { class: "name", title: item.name, text: item.name }),
        el("div", { class: "hint", text: ZV.formatSize(item.size) }),
      ]),
      el("div", { class: "actions" }, [
        ZV.button("Copy", () => ZV.copy("media:" + item.name, "reference"), "small ghost",
          { title: "Copy media:" + item.name }),
        ZV.link("Open", src, "small ghost", { target: "_blank", rel: "noopener" }),
        ZV.button("Delete", () => ZV.remove("\"" + item.name + "\"", "/media/" + item.name,
          ZV.views.media), "small ghost danger"),
      ]),
    ]);
  }

  // ---------------------------------------------------------------
  // site settings
  // ---------------------------------------------------------------

  function select(items, current, emptyLabel) {
    return el("select", {}, [el("option", { value: "", text: emptyLabel })].concat(
      items.map((i) => el("option", { value: i.name, text: i.name, selected: i.name === current }))));
  }

  ZV.views.site = async function siteView() {
    let site, layouts, styles, snippets;
    try {
      [site, layouts, styles, snippets] = await Promise.all(
        ["/site", "/layouts", "/styles", "/snippets"].map((p) => api("GET", p)));
    } catch (err) {
      return ZV.failed(err);
    }
    const title = el("input", { type: "text", value: site.title, maxlength: "200" });
    const layout = select(layouts, site.active_layout, "Built-in default");
    const style = select(styles, site.active_style, "No stylesheet");
    const switches = snippets.map((s) => el("label", { class: "switch" }, [
      el("input", { type: "checkbox", value: s.name,
        props: { checked: site.enabled_snippets.includes(s.name) } }),
      el("span", { class: "mono", text: s.name }),
    ]));
    const save = el("button", { type: "submit", class: "btn primary" }, "Save settings");
    const form = el("form", { on: { submit: async (e) => {
      e.preventDefault();
      const enabled = switches.map((l) => l.firstChild).filter((c) => c.checked).map((c) => c.value);
      try {
        await ZV.busy(save, ZV.saveSite({
          title: title.value, active_layout: layout.value || null,
          active_style: style.value || null, enabled_snippets: enabled,
        }));
      } catch (err) {
        ZV.failed(err);
      }
    } } }, [
      card("General", [ZV.field("Site title", title, "Shown in the header and browser tab.")]),
      card("Appearance", [el("div", { class: "form-grid" }, [
        ZV.field("Stylesheet", style), ZV.field("Layout", layout)])]),
      card("Snippets", switches.length ? switches
        : [el("p", { class: "hint", text: "No snippets uploaded." })]),
      el("div", { class: "actions form-actions" }, [save]),
    ]);
    ZV.show(ZV.page({ title: "Site settings" }, [form]));
  };

  function card(title, children) {
    return el("div", { class: "card" }, el("div", { class: "card-body" },
      [el("h2", { text: title })].concat(children)));
  }
})();
