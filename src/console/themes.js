// zerverg console: the Themes page. A theme is a layout and a
// stylesheet with the same name. Each one is previewed on the site's
// own content before anything changes on the live site.
"use strict";

(function () {
  const { el, api } = ZV;

  const known = {
    default: ["Blog", "Charcoal terminal look, monospace type, a sidebar " +
      "with search and recent posts."],
    magazine: ["Magazine", "A masthead, serif headlines and the latest " +
      "stories as image cards on the front page."],
    landing: ["Landing / shop", "A bold hero, featured entries as " +
      "product-style cards and big buttons."],
    newsletter: ["Newsletter", "One calm column on warm paper, made for " +
      "reading, with past issues listed below."],
  };

  const order = Object.keys(known);

  function themeNames(layouts, styles) {
    const styleSet = new Set(styles.map((s) => s.name));
    return layouts.map((l) => l.name).filter((n) => styleSet.has(n))
      .sort((a, b) => rank(a) - rank(b) || a.localeCompare(b));
  }

  function rank(name) {
    const i = order.indexOf(name);
    return i < 0 ? order.length : i;
  }

  function describe(name) {
    return known[name] || [name, "A custom theme: the layout and " +
      "stylesheet named \"" + name + "\"."];
  }

  function previewHtml(name, page) {
    return api("GET", "/themes/" + encodeURIComponent(name) + "/preview",
      undefined, page ? { page } : undefined);
  }

  /// A frame that renders a page at desktop width, scaled to fit.
  function scaledFrame(className) {
    const frame = el("iframe", { sandbox: "allow-same-origin", tabindex: "-1",
      "aria-hidden": "true", title: "" });
    const box = el("div", { class: className }, frame);
    new ResizeObserver(() => {
      frame.style.transform = "scale(" + box.clientWidth / 1280 + ")";
    }).observe(box);
    return { box, frame };
  }

  ZV.views.themes = async function themesView() {
    let layouts, styles, site, entries;
    try {
      [layouts, styles, site, entries] = await Promise.all(
        ["/layouts", "/styles", "/site", "/posts"].map((p) => api("GET", p)));
    } catch (err) {
      return ZV.failed(err);
    }
    const names = themeNames(layouts, styles);
    const state = { site, entries, names };
    const previewBox = el("div");
    const grid = el("div", { class: "theme-grid" },
      names.map((n) => themeCard(n, state, previewBox)));
    const mixed = site.active_layout !== site.active_style;
    ZV.show(ZV.page({
      title: "Themes",
      lead: "A theme is a layout plus a stylesheet. Preview any of them " +
        "with your own content; the live site only changes when you " +
        "choose \"Use this theme\".",
    }, [
      mixed ? el("p", { class: "callout info", text: "Your site mixes the " +
        "layout \"" + (site.active_layout || "built-in") + "\" with the " +
        "stylesheet \"" + (site.active_style || "none") + "\"." }) : null,
      previewBox,
      names.length ? grid : el("div", { class: "card" }, ZV.empty("No themes",
        "Create a layout and a stylesheet with the same name to make one.")),
    ]));
  };

  function themeCard(name, state, previewBox) {
    const [title, text] = describe(name);
    const inUse = state.site.active_layout === name &&
      state.site.active_style === name;
    const thumb = scaledFrame("theme-thumb");
    previewHtml(name).then((html) => { thumb.frame.srcdoc = html; }, () => {});
    return el("div", { class: "card theme-card" }, [
      thumb.box,
      el("div", { class: "card-body" }, [
        el("div", { class: "theme-title" }, [
          el("h2", { text: title }),
          inUse ? el("span", { class: "badge on", text: "in use" }) : null,
        ]),
        el("p", { class: "hint", text }),
        el("div", { class: "actions" }, [
          ZV.button("Preview", () => openPreview(name, state, previewBox)),
          inUse ? null : ZV.button("Use this theme", () => useTheme(name, state),
            "primary"),
        ]),
      ]),
    ]);
  }

  function pageSelect(entries) {
    return el("select", { "aria-label": "Page to preview" },
      [el("option", { value: "", text: "Home page" })].concat(entries
        .filter((e) => e.slug !== "index")
        .map((e) => el("option", { value: e.slug,
          text: (e.meta.kind === "page" ? "Page: " : "Post: ") +
            (e.meta.title || e.slug) }))));
  }

  function openPreview(name, state, previewBox) {
    const [title] = describe(name);
    const frame = el("iframe", { title: "Preview of " + title,
      sandbox: "allow-same-origin" });
    const select = pageSelect(state.entries);
    const load = async () => {
      try {
        frame.srcdoc = await previewHtml(name, select.value);
      } catch (err) {
        ZV.failed(err);
      }
    };
    select.addEventListener("change", load);
    const inUse = state.site.active_layout === name &&
      state.site.active_style === name;
    previewBox.replaceChildren(el("div", { class: "card theme-preview" }, [
      el("div", { class: "editor-head" }, [
        el("strong", { text: "Previewing: " + title }),
        el("span", { class: "spacer" }),
        select,
        inUse ? null : ZV.button("Use this theme", () => useTheme(name, state),
          "primary small"),
        ZV.button("Close", () => previewBox.replaceChildren(), "small"),
      ]),
      frame,
    ]));
    load();
    previewBox.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  async function useTheme(name, state) {
    const [title] = describe(name);
    const yes = await ZV.confirm({
      title: "Switch the site to " + title + "?",
      message: "Visitors see the new look right away. You can switch " +
        "back at any time; posts and pages stay as they are.",
      action: "Use this theme",
    });
    if (!yes) return;
    try {
      await api("PUT", "/site", Object.assign({}, state.site,
        { active_layout: name, active_style: name }));
      ZV.toast("Your site now uses " + title + ".");
      ZV.views.themes();
    } catch (err) {
      ZV.failed(err);
    }
  }
})();
