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

  /// Uploads one media file under a free name into `folder`: "" for
  /// site-wide files, "posts/<slug>/" or "pages/<slug>/" for an
  /// entry's own. Resolves with its path, as `media:` references use.
  ZV.uploadMedia = async function (file, taken, folder) {
    let path = (folder || "") + ZV.mediaName(file.name);
    if (taken && taken.has(path)) {
      const dot = path.lastIndexOf(".");
      path = path.slice(0, dot) + "-" + Date.now().toString(36) + path.slice(dot);
    }
    await api("PUT", "/media/" + path, file);
    if (taken) taken.add(path);
    return path;
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
    let published, drafts, media;
    try {
      [published, drafts, media] = await Promise.all(
        ["/posts", "/drafts", "/media"].map((p) => api("GET", p)));
    } catch (err) {
      return ZV.failed(err);
    }
    const entries = withDrafts(published, drafts);
    const paths = media.map((m) => m.path);
    const listBox = el("div");
    const search = el("input", { type: "search", placeholder: "Search titles and tags",
      "aria-label": "Search posts" });
    let kind = "all";
    const kinds = segmented(["all", "post", "page"], ["All", "Posts", "Pages"], (k) => {
      kind = k;
      render();
    });
    const render = () => listBox.replaceChildren(postList(entries, paths, search.value, kind));
    search.addEventListener("input", render);
    render();
    ZV.show(ZV.page({
      title: "Posts & pages",
      lead: "Everything on your site. A page named \"index\" becomes your home page.",
      actions: [
        ZV.button("Upload files", () => uploadEntries(entries)),
        ZV.link("New post", "#/write", "primary"),
      ],
    }, [draftBanner(drafts), el("div", { class: "toolbar" }, [search, kinds]), listBox]));
  };

  /// One row per slug: drafts of new entries first, then published
  /// entries, each marked when a draft of it is pending.
  function withDrafts(published, drafts) {
    const live = new Set(published.map((e) => e.slug));
    const pending = new Set(drafts.map((d) => d.slug));
    return drafts.filter((d) => !live.has(d.slug))
      .map((d) => Object.assign({ live: false, draft: true }, d))
      .concat(published.map((e) => Object.assign({ live: true, draft: pending.has(e.slug) }, e)));
  }

  function draftBanner(drafts) {
    if (!drafts.length) return null;
    const count = drafts.length === 1 ? "1 unpublished draft." : drafts.length + " unpublished drafts.";
    return el("div", { class: "callout draft", role: "status" }, [
      el("strong", { text: count }),
      el("span", { text: "Drafts aren't on the site until you publish them; they're marked below." }),
    ]);
  }

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

  function postList(entries, paths, query, kind) {
    const q = query.trim().toLowerCase();
    const shown = entries.filter((e) => (kind === "all" || e.meta.kind === kind) &&
      (!q || (e.meta.title + " " + e.slug + " " + e.meta.tags).toLowerCase().includes(q)));
    if (!entries.length) {
      return el("div", { class: "card" }, ZV.empty("No posts yet",
        "Write your first post; it appears on the site as soon as you publish it.",
        ZV.link("Write a post", "#/write", "primary")));
    }
    if (!shown.length) {
      return el("div", { class: "card" }, ZV.empty("Nothing matches",
        "Try a different search or filter."));
    }
    return el("ul", { class: "card list" }, shown.map((e) => postRow(e, paths)));
  }

  function postRow(entry, paths) {
    const meta = entry.meta;
    const editHref = "#/write/" + encodeURIComponent(entry.slug);
    const sub = [
      el("span", { class: "mono", text: "/" + entry.slug }),
      meta.date ? el("span", { text: meta.date }) : null,
      meta.tags ? el("span", { text: meta.tags }) : null,
    ];
    const name = "\"" + (meta.title || entry.slug) + "\"";
    return el("li", { class: "list-row" }, [
      el("div", { class: "main" }, [
        el("a", { class: "title", href: editHref, text: meta.title || entry.slug }),
        el("div", { class: "sub" }, sub),
      ]),
      entry.draft ? el("span", { class: "badge draft",
        text: entry.live ? "unpublished changes" : "draft" }) : null,
      el("span", { class: meta.kind === "page" ? "badge accent" : "badge", text: meta.kind }),
      el("span", { class: "badge", text: formatLabel[entry.format] || entry.format }),
      el("div", { class: "actions" }, [
        ZV.link("Edit", editHref, "small"),
        entry.live ? ZV.link("View ↗", ZV.siteUrl(entry.slug), "small ghost",
          { target: "_blank", rel: "noopener" }) : null,
        ZV.button("Delete", () => ZV.removeEntry({
          what: entry.live ? name : "draft " + name,
          path: (entry.live ? "/posts/" : "/drafts/") + entry.slug,
          // A pending draft still uses the media; only offer it with the last version.
          folders: entry.live && entry.draft ? [] : ZV.mediaFolders(paths, entry.slug),
          then: ZV.views.posts,
        }), "small ghost danger"),
      ]),
    ]);
  }

  /// The media folders of entry `slug`, "posts/<slug>/" or
  /// "pages/<slug>/", with how many files each holds.
  ZV.mediaFolders = function (paths, slug) {
    const counts = new Map();
    for (const path of paths) {
      const cut = path.lastIndexOf("/");
      const folder = path.slice(0, cut + 1);
      if (folder !== "posts/" + slug + "/" && folder !== "pages/" + slug + "/") continue;
      counts.set(folder, (counts.get(folder) || 0) + 1);
    }
    return [...counts].map(([folder, files]) => ({ folder, files }));
  };

  /// Deletes an entry or a draft. With `folders`, the entry's media,
  /// offers to delete those too; they stay unless asked.
  ZV.removeEntry = async function ({ what, path, folders, then }) {
    if (!folders.length) return ZV.remove(what, path, then);
    const files = folders.reduce((n, f) => n + f.files, 0);
    const withMedia = await ZV.confirmOption({
      title: "Delete " + what + "?",
      message: "This can't be undone.",
      option: "Also delete its media: " + files + (files === 1 ? " file in " : " files in ") +
        folders.map((f) => f.folder).join(" and "),
      action: "Delete",
      danger: true,
    });
    if (withMedia === null) return;
    try {
      await api("DELETE", path);
      if (withMedia) {
        for (const f of folders) await api("DELETE", "/media/" + f.folder.slice(0, -1));
      }
      ZV.toast("Deleted " + what + (withMedia ? " and its media." : "."));
    } catch (err) {
      ZV.failed(err);
    }
    then();
  };

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
    let items, published, drafts;
    try {
      [items, published, drafts] = await Promise.all(
        ["/media", "/posts", "/drafts"].map((p) => api("GET", p)));
    } catch (err) {
      return ZV.failed(err);
    }
    // Published titles win over a draft's working title.
    const titles = new Map(drafts.concat(published).map((e) => [e.slug, e.meta.title || e.slug]));
    const taken = new Set(items.map((i) => i.path));
    const upload = async (files) => {
      for (const file of files) {
        try {
          const path = await ZV.uploadMedia(file, taken, "");
          ZV.toast("Uploaded \"" + path + "\".");
        } catch (err) {
          ZV.toast(file.name + ": " + err.message, "error");
        }
      }
      ZV.views.media();
    };
    const groups = items.length ? mediaSections(items, titles)
      : el("div", { class: "card" }, ZV.empty("No media yet",
        "Uploaded images and videos show up here."));
    ZV.show(ZV.page({
      title: "Media",
      lead: ["Images and videos. Files uploaded here are site-wide, for logos and " +
        "banners; each post or page keeps its own in a folder, filled by the Write " +
        "view's Image button. In Markdown write ",
        el("code", { text: "![description](media:photo.jpg)" }), "."],
    }, [ZV.dropzone("Upload site-wide images or videos", mediaAccept, upload)].concat(groups)));
  };

  /// Site-wide files, then a collapsible section each for posts and
  /// pages, holding one collapsible folder per entry.
  function mediaSections(items, titles) {
    const site = [];
    const folders = { posts: new Map(), pages: new Map() };
    for (const item of items) {
      const [dir, slug] = item.path.split("/");
      if (!folders[dir] || !slug) {
        site.push(item);
        continue;
      }
      if (!folders[dir].has(slug)) folders[dir].set(slug, []);
      folders[dir].get(slug).push(item);
    }
    return [
      site.length ? el("section", { class: "media-group" }, [
        el("h2", { text: "Site-wide" }), mediaGrid(site)]) : null,
      kindSection("posts", "Posts", folders.posts, titles),
      kindSection("pages", "Pages", folders.pages, titles),
    ];
  }

  /// Which sections are open, kept while the console runs, so a
  /// re-render after an upload or delete doesn't fold everything.
  const openFolds = new Set(["posts", "pages"]);

  function fold(key, summary, body) {
    const box = el("details", { class: "fold", open: openFolds.has(key) },
      [el("summary", {}, summary)].concat(body));
    box.addEventListener("toggle", () => {
      if (box.open) openFolds.add(key);
      else openFolds.delete(key);
    });
    return box;
  }

  const countOf = (n, noun) => n + " " + noun + (n === 1 ? "" : "s");

  function kindSection(dir, label, entries, titles) {
    if (!entries.size) return null;
    const files = [...entries.values()].reduce((n, list) => n + list.length, 0);
    return fold(dir, [
      el("h2", { text: label }),
      el("span", { class: "hint", text: countOf(entries.size, label.slice(0, -1).toLowerCase()) +
        ", " + countOf(files, "file") }),
    ], [...entries].map(([slug, list]) => entryFolder(dir, slug, list, titles)));
  }

  function entryFolder(dir, slug, list, titles) {
    const folder = dir + "/" + slug;
    const title = titles.get(slug);
    // Inside a summary a click would also fold the section.
    const remove = ZV.button("Delete folder", (e) => {
      e.preventDefault();
      ZV.remove("the folder \"" + folder + "/\" and its " + countOf(list.length, "file"),
        "/media/" + folder, ZV.views.media);
    }, "small ghost danger");
    return fold(folder, [
      el("strong", { text: title || slug }),
      el("span", { class: "mono hint", text: folder + "/" }),
      title ? null : el("span", { class: "badge", text: "no entry" }),
      el("span", { class: "badge", text: countOf(list.length, "file") }),
      remove,
    ], [mediaGrid(list)]);
  }

  function mediaGrid(items) {
    return el("div", { class: "media-grid" }, items.map(mediaCard));
  }

  function mediaCard(item) {
    const src = "/media/" + item.path;
    const preview = ZV.isImage(item.name) ? el("img", { src, alt: "", loading: "lazy" })
      : ZV.isVideo(item.name) ? el("video", { src, muted: true, preload: "metadata" })
        : el("span", { text: item.content_type });
    return el("div", { class: "card media-card" }, [
      el("div", { class: "thumb" }, preview),
      el("div", { class: "meta" }, [
        el("div", { class: "name", title: item.path, text: item.name }),
        el("div", { class: "hint", text: ZV.formatSize(item.size) }),
      ]),
      el("div", { class: "actions" }, [
        ZV.button("Copy", () => ZV.copy("media:" + item.path, "reference"), "small ghost",
          { title: "Copy media:" + item.path }),
        ZV.link("Open", src, "small ghost", { target: "_blank", rel: "noopener" }),
        ZV.button("Delete", () => ZV.remove("\"" + item.path + "\"", src,
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
