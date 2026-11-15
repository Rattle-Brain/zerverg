// zerverg console: a thin client for /api/v1.
//
// No framework and no build step. Every view fetches from the REST
// API and builds DOM nodes with textContent, never innerHTML, so
// content shown here is never interpreted as markup.
(function () {
  "use strict";

  var session = null;
  var content = document.getElementById("content");

  // ---------------------------------------------------------------
  // dom helpers
  // ---------------------------------------------------------------

  function el(tag, attrs, children) {
    var node = document.createElement(tag);
    Object.keys(attrs || {}).forEach(function (key) {
      var value = attrs[key];
      if (key === "text") node.textContent = value;
      else if (key === "class") node.className = value;
      else if (key === "on") {
        Object.keys(value).forEach(function (ev) {
          node.addEventListener(ev, value[ev]);
        });
      } else if (value === true) node.setAttribute(key, "");
      else if (value !== false && value != null) node.setAttribute(key, value);
    });
    (children || []).forEach(function (child) {
      if (child == null) return;
      node.appendChild(typeof child === "string"
        ? document.createTextNode(child) : child);
    });
    return node;
  }

  function show(nodes, narrow) {
    content.className = narrow ? "narrow" : "";
    content.replaceChildren.apply(content, nodes);
  }

  function button(label, onClick, cls) {
    return el("button", {
      type: "button", class: cls || "small", text: label,
      on: { click: onClick },
    });
  }

  function row(label, input) {
    return el("div", { class: "row" }, [el("label", { text: label }), input]);
  }

  function table(headers, rows, emptyText) {
    var head = el("tr", {}, headers.map(function (h) {
      return el("th", { text: h });
    }));
    var body = rows.length ? rows : [el("tr", {}, [el("td", {
      class: "empty", colspan: String(headers.length),
      text: emptyText || "nothing here yet",
    })])];
    return el("table", { class: "list" }, [
      el("thead", {}, [head]), el("tbody", {}, body),
    ]);
  }

  function flash(message, kind) {
    var box = document.getElementById("flash");
    box.textContent = message;
    box.className = kind || "ok";
    box.hidden = false;
    clearTimeout(flash.timer);
    flash.timer = setTimeout(function () { box.hidden = true; }, 6000);
  }

  function failed(err) { flash(err.message, "error"); }

  function formatSize(bytes) {
    if (bytes < 1024) return bytes + " B";
    if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KiB";
    return (bytes / 1048576).toFixed(1) + " MiB";
  }

  // "My Post.HTML" -> "my-post"
  function slugify(name) {
    return name.toLowerCase()
      .replace(/\.[^.]*$/, "")
      .replace(/[^a-z0-9_-]+/g, "-")
      .replace(/^[^a-z0-9]+/, "")
      .replace(/-+$/, "")
      .slice(0, 64);
  }

  function mediaName(name) {
    var dot = name.lastIndexOf(".");
    if (dot < 0) return slugify(name);
    return slugify(name.slice(0, dot)) + "." + name.slice(dot + 1).toLowerCase();
  }

  function siteUrl(path) {
    var port = session ? session.public_port : 7080;
    return location.protocol + "//" + location.hostname + ":" + port +
      "/" + (path || "");
  }

  // ---------------------------------------------------------------
  // api
  // ---------------------------------------------------------------

  function api(method, path, body) {
    var options = {
      method: method,
      credentials: "same-origin",
      headers: { "X-Requested-With": "zerverg" },
    };
    if (body !== undefined) {
      if (body instanceof Blob) options.body = body;
      else {
        options.body = JSON.stringify(body);
        options.headers["Content-Type"] = "application/json";
      }
    }
    return fetch("/api/v1" + path, options).then(function (res) {
      var type = res.headers.get("content-type") || "";
      var parse = res.status === 204 ? Promise.resolve(null)
        : type.indexOf("application/json") === 0 ? res.json() : res.text();
      return parse.then(function (data) {
        if (res.ok) return data;
        if (res.status === 401 && session) { session = null; route(); }
        var reason = data && data.error ? data.error : res.statusText;
        throw new Error(res.status + " " + reason);
      });
    });
  }

  // ---------------------------------------------------------------
  // routing
  // ---------------------------------------------------------------

  var views = {
    posts: postsView,
    layouts: libraryView("layouts", ".xml", "layout"),
    styles: libraryView("styles", ".css", "style"),
    snippets: libraryView("snippets", ".js", "snippet"),
    media: mediaView,
    site: siteView,
    account: accountView,
  };

  function route() {
    var signedIn = !!(session && session.authenticated);
    document.getElementById("tabs").hidden = !signedIn;
    document.getElementById("userbox").hidden = !signedIn;
    if (!signedIn) return loginView();
    document.getElementById("username").textContent = session.user;
    document.getElementById("sitelink").href = siteUrl("");
    if (session.must_change_password) return forcedPasswordView();
    var name = location.hash.replace(/^#\/?/, "").replace(/\?.*$/, "");
    if (!name || name === "login") name = "posts";
    var view = views[name] || postsView;
    markTab(name);
    view();
  }

  function markTab(name) {
    document.querySelectorAll("#tabs a").forEach(function (a) {
      a.classList.toggle("active", a.getAttribute("href") === "#/" + name);
    });
  }

  function refreshSession() {
    return api("GET", "/auth/session").then(function (data) {
      session = data;
      route();
    });
  }

  // ---------------------------------------------------------------
  // login and password
  // ---------------------------------------------------------------

  function loginView() {
    var method = session ? session.auth_method : "password";
    if (method === "oauth") return providerLoginView();
    if (method !== "password") {
      return show([el("h1", { text: "Not signed in" }), el("p", {
        text: "This console uses " + method +
          " authentication. Reach it through your identity proxy.",
      })], true);
    }
    var user = el("input", { type: "text", autocomplete: "username" });
    var pass = el("input", { type: "password", autocomplete: "current-password" });
    var form = el("form", { on: { submit: function (event) {
      event.preventDefault();
      api("POST", "/auth/login", { username: user.value, password: pass.value })
        .then(refreshSession).catch(failed);
    } } }, [
      row("Username", user),
      row("Password", pass),
      el("div", { class: "row" }, [
        el("button", { type: "submit", class: "primary", text: "Log in" }),
      ]),
    ]);
    show([el("h1", { text: "Log in" }), form], true);
    user.focus();
  }

  // "Sign in with Google / GitHub / ...": plain links; the server
  // does the redirects and sets the session cookie on the way back.
  function providerLoginView() {
    var failedBefore = /error=/.test(location.hash);
    var buttons = (session.providers || []).map(function (p) {
      return el("a", {
        class: "button provider",
        href: "/api/v1/auth/oauth/" + encodeURIComponent(p.name) + "/start",
        text: "Sign in with " + p.label,
      });
    });
    show([
      el("h1", { text: "Sign in" }),
      failedBefore ? el("div", { class: "warning", text: "Sign-in failed. " +
        "Your account may not be on this site's allowlist." }) : null,
      el("div", { class: "providers" }, buttons),
    ], true);
  }

  function passwordForm(onDone) {
    var current = el("input", { type: "password", autocomplete: "current-password" });
    var next = el("input", { type: "password", autocomplete: "new-password" });
    var again = el("input", { type: "password", autocomplete: "new-password" });
    return el("form", { on: { submit: function (event) {
      event.preventDefault();
      if (next.value !== again.value) {
        return flash("The new passwords do not match.", "error");
      }
      api("POST", "/auth/password", {
        current_password: current.value, new_password: next.value,
      }).then(function () {
        flash("Password changed. Other sessions were logged out.");
        onDone();
      }).catch(failed);
    } } }, [
      row("Current password", current),
      row("New password", next),
      row("Repeat new password", again),
      el("p", { class: "help",
        text: "At least 8 characters; not \"admin\" and not the user name." }),
      el("button", { type: "submit", class: "primary", text: "Change password" }),
    ]);
  }

  function forcedPasswordView() {
    document.getElementById("tabs").hidden = true;
    show([
      el("h1", { text: "Change the default password" }),
      el("div", { class: "warning", text: "This server still uses the " +
        "factory credentials (admin / admin). Choose a new password " +
        "before doing anything else." }),
      passwordForm(refreshSession),
    ], true);
  }

  function accountView() {
    var nodes = [
      el("h1", { text: "Account" }),
      table(["", ""], [
        el("tr", {}, [el("th", { text: "User" }), el("td", { text: session.user })]),
        el("tr", {}, [el("th", { text: "Authentication" }),
          el("td", { text: session.auth_method })]),
        el("tr", {}, [el("th", { text: "Password source" }),
          el("td", { text: session.password_source })]),
      ]),
    ];
    if (session.auth_method !== "password") {
      nodes.push(el("p", { class: "help", text: "Passwords are not used " +
        "with this authentication method." }));
    } else if (session.password_source === "config") {
      nodes.push(el("p", { class: "help", text: "The password is set in " +
        "the server configuration (admin_password_hash) and cannot be " +
        "changed here." }));
    } else {
      nodes.push(el("fieldset", {}, [el("legend", { text: "Change password" }),
        passwordForm(refreshSession)]));
    }
    show(nodes);
  }

  // ---------------------------------------------------------------
  // shared pieces
  // ---------------------------------------------------------------

  function viewer(title, text, extra) {
    var old = document.getElementById("viewer");
    if (old) old.remove();
    var box = el("div", { id: "viewer" }, [
      el("div", { class: "bar" }, [
        el("b", { text: title }),
        el("span", {}, (extra || []).concat([
          button("close", function () { box.remove(); }),
        ])),
      ]),
      el("pre", { text: text }),
    ]);
    content.appendChild(box);
    box.scrollIntoView({ behavior: "smooth", block: "nearest" });
  }

  function uploadForm(legend, accept, nameFromFile, help, onUpload) {
    var file = el("input", { type: "file", accept: accept });
    var name = el("input", { type: "text", placeholder: "derived from file name" });
    file.addEventListener("change", function () {
      if (file.files[0]) name.value = nameFromFile(file.files[0].name);
    });
    return el("fieldset", {}, [
      el("legend", { text: legend }),
      row("File", file),
      row("Name", name),
      el("p", { class: "help", text: help }),
      el("button", { type: "button", class: "primary", text: "Upload",
        on: { click: function () {
          if (!file.files[0]) return flash("Choose a file first.", "error");
          var target = name.value || nameFromFile(file.files[0].name);
          onUpload(target, file.files[0]);
        } } }),
    ]);
  }

  function confirmDelete(what, path, then) {
    if (!confirm("Delete " + what + "? This cannot be undone.")) return;
    api("DELETE", path).then(function () {
      flash("Deleted " + what + ".");
      then();
    }).catch(failed);
  }

  // ---------------------------------------------------------------
  // posts and pages
  // ---------------------------------------------------------------

  function postsView() {
    api("GET", "/posts").then(function (entries) {
      var rows = entries.map(function (entry) {
        var meta = entry.meta;
        return el("tr", {}, [
          el("td", { class: "mono", text: entry.slug }),
          el("td", { text: meta.title }),
          el("td", {}, [el("span", { class: "badge " + meta.kind, text: meta.kind })]),
          el("td", { text: meta.date }),
          el("td", { text: meta.tags }),
          el("td", { class: "actions" }, [
            button("view", function () { viewPost(entry.slug); }), " ",
            el("a", { class: "button small", href: siteUrl(entry.slug),
              target: "_blank", rel: "noopener", text: "open" }), " ",
            button("delete", function () {
              confirmDelete("\"" + entry.slug + "\"", "/posts/" + entry.slug, postsView);
            }, "small danger"),
          ]),
        ]);
      });
      show([
        el("h1", { text: "Posts & pages" }),
        el("p", { class: "help", text: "Entries are HTML files. Metadata " +
          "(title, date, kind, tags, layout) is read from zerverg:* meta tags. " +
          "The page named \"index\" is the home page." }),
        table(["Slug", "Title", "Kind", "Date", "Tags", ""], rows),
        uploadForm("Upload an entry", ".html,.htm,text/html", slugify,
          "Uploading with an existing name replaces that entry.",
          function (slug, file) {
            api("PUT", "/posts/" + slug, file).then(function () {
              flash("Uploaded \"" + slug + "\".");
              postsView();
            }).catch(failed);
          }),
      ]);
    }).catch(failed);
  }

  function viewPost(slug) {
    api("GET", "/posts/" + slug).then(function (html) {
      viewer(slug + ".html", html);
    }).catch(failed);
  }

  // ---------------------------------------------------------------
  // layouts, styles, snippets
  // ---------------------------------------------------------------

  function libraryView(kind, ext, noun) {
    return function view() {
      Promise.all([api("GET", "/" + kind), api("GET", "/site")])
        .then(function (results) {
          renderLibrary(kind, ext, noun, results[0], results[1]);
        }).catch(failed);
    };
  }

  function isActive(kind, name, site) {
    if (kind === "layouts") return site.active_layout === name;
    if (kind === "styles") return site.active_style === name;
    return site.enabled_snippets.indexOf(name) >= 0;
  }

  function renderLibrary(kind, ext, noun, items, site) {
    var rows = items.map(function (item) {
      var active = isActive(kind, item.name, site);
      return el("tr", {}, [
        el("td", { class: "mono", text: item.name }),
        el("td", { text: "v" + item.version }),
        el("td", {}, [el("span", { class: active ? "badge on" : "badge",
          text: active ? (kind === "snippets" ? "enabled" : "active") : "-" })]),
        el("td", { class: "actions" }, [
          button("view", function () { viewItem(kind, item.name, null); }), " ",
          button("history", function () { history(kind, item.name); }), " ",
          activationButton(kind, item.name, active, site), " ",
          button("delete", function () {
            confirmDelete(noun + " \"" + item.name + "\" and its history",
              "/" + kind + "/" + item.name, views[kind]);
          }, "small danger"),
        ]),
      ]);
    });
    var title = kind.charAt(0).toUpperCase() + kind.slice(1);
    show([
      el("h1", { text: title }),
      table(["Name", "Current", "Status", ""], rows),
      uploadForm("Upload a " + noun, ext, slugify,
        "Uploading with an existing name adds a new version and makes it " +
        "current; older versions stay available under \"history\".",
        function (name, file) {
          api("PUT", "/" + kind + "/" + name, file).then(function (res) {
            flash("Uploaded " + noun + " \"" + name + "\" as v" + res.version + ".");
            views[kind]();
          }).catch(failed);
        }),
    ]);
  }

  function activationButton(kind, name, active, site) {
    if (kind === "snippets") {
      return button(active ? "disable" : "enable", function () {
        var list = site.enabled_snippets.filter(function (n) { return n !== name; });
        if (!active) list.push(name);
        saveSite(Object.assign({}, site, { enabled_snippets: list }), views[kind]);
      });
    }
    if (active) return null;
    return button("activate", function () {
      var change = kind === "layouts" ? { active_layout: name } : { active_style: name };
      saveSite(Object.assign({}, site, change), views[kind]);
    });
  }

  function viewItem(kind, name, version) {
    var query = version ? "?version=" + version : "";
    api("GET", "/" + kind + "/" + name + query).then(function (text) {
      viewer(name + (version ? " (v" + version + ")" : " (current)"), text);
    }).catch(failed);
  }

  function history(kind, name) {
    api("GET", "/" + kind + "/" + name + "/versions").then(function (versions) {
      var lines = versions.slice().reverse().map(function (v) {
        return "v" + v;
      }).join("\n");
      var buttons = versions.slice().reverse().map(function (v) {
        return el("span", {}, [
          button("view v" + v, function () { viewItem(kind, name, v); }), " ",
          button("restore v" + v, function () { rollback(kind, name, v); }), " ",
        ]);
      });
      viewer(name + ": " + versions.length + " version(s)", lines, buttons);
    }).catch(failed);
  }

  function rollback(kind, name, version) {
    api("POST", "/" + kind + "/" + name + "/rollback?version=" + version)
      .then(function () {
        flash("\"" + name + "\" is now at v" + version + ".");
        views[kind]();
      }).catch(failed);
  }

  // ---------------------------------------------------------------
  // media
  // ---------------------------------------------------------------

  function mediaView() {
    api("GET", "/media").then(function (items) {
      var rows = items.map(function (item) {
        var isImage = item.content_type.indexOf("image/") === 0;
        return el("tr", {}, [
          el("td", {}, [isImage ? el("img", { class: "thumb",
            src: "/media/" + item.name, alt: "" }) : el("span", { text: "-" })]),
          el("td", { class: "mono", text: item.name }),
          el("td", { class: "mono", text: "media:" + item.name }),
          el("td", { text: item.content_type }),
          el("td", { text: formatSize(item.size) }),
          el("td", { class: "actions" }, [
            el("a", { class: "button small", href: "/media/" + item.name,
              target: "_blank", rel: "noopener", text: "open" }), " ",
            button("delete", function () {
              confirmDelete("\"" + item.name + "\"", "/media/" + item.name, mediaView);
            }, "small danger"),
          ]),
        ]);
      });
      show([
        el("h1", { text: "Media" }),
        el("p", { class: "help", text: "Reference files from content as " +
          "src=\"media:name.ext\"." }),
        table(["", "File", "Reference", "Type", "Size", ""], rows),
        uploadForm("Upload media",
          ".png,.jpg,.jpeg,.gif,.webp,.avif,.svg,.ico,.mp4,.webm,.ogv",
          mediaName, "Images: png, jpg, gif, webp, avif, svg, ico. " +
          "Video: mp4, webm, ogv. Size limits and a total quota apply.",
          function (name, file) {
            api("PUT", "/media/" + name, file).then(function () {
              flash("Uploaded \"" + name + "\".");
              mediaView();
            }).catch(failed);
          }),
      ]);
    }).catch(failed);
  }

  // ---------------------------------------------------------------
  // site settings
  // ---------------------------------------------------------------

  function saveSite(site, then) {
    api("PUT", "/site", site).then(function () {
      flash("Site settings saved.");
      then();
    }).catch(failed);
  }

  function select(options, current, emptyLabel) {
    var node = el("select", {}, [el("option", { value: "", text: emptyLabel })]);
    options.forEach(function (item) {
      node.appendChild(el("option", { value: item.name, text: item.name,
        selected: item.name === current }));
    });
    return node;
  }

  function siteView() {
    Promise.all(["/site", "/layouts", "/styles", "/snippets"].map(function (p) {
      return api("GET", p);
    })).then(function (r) {
      var site = r[0];
      var title = el("input", { type: "text", value: site.title });
      var layout = select(r[1], site.active_layout, "(built-in default)");
      var style = select(r[2], site.active_style, "(no stylesheet)");
      var boxes = r[3].map(function (item) {
        return el("label", { class: "mono" }, [
          el("input", { type: "checkbox", value: item.name,
            checked: site.enabled_snippets.indexOf(item.name) >= 0 }),
          " " + item.name + "  ",
        ]);
      });
      var save = el("button", { type: "button", class: "primary",
        text: "Save settings", on: { click: function () {
          var enabled = boxes.map(function (b) { return b.firstChild; })
            .filter(function (c) { return c.checked; })
            .map(function (c) { return c.value; });
          saveSite({
            title: title.value,
            active_layout: layout.value || null,
            active_style: style.value || null,
            enabled_snippets: enabled,
          }, siteView);
        } } });
      show([
        el("h1", { text: "Site settings" }),
        el("fieldset", {}, [el("legend", { text: "General" }),
          row("Site title", title),
          row("Active layout", layout),
          row("Active style", style),
          row("Enabled snippets", el("span", {}, boxes.length ? boxes
            : [el("i", { text: "no snippets uploaded" })])),
          el("div", { class: "row" }, [save]),
        ]),
      ]);
    }).catch(failed);
  }

  // ---------------------------------------------------------------
  // start
  // ---------------------------------------------------------------

  document.getElementById("logout").addEventListener("click", function (e) {
    e.preventDefault();
    api("POST", "/auth/logout").then(function () {
      location.hash = "";
      return refreshSession();
    }).catch(failed);
  });

  window.addEventListener("hashchange", route);
  refreshSession().catch(failed);
})();
