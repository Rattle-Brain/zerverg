// zerverg console core: DOM helpers, API client, messages, dialogs,
// routing, login and account. Views live in views.js, editor.js and
// write.js and register themselves on window.ZV.
//
// No framework, no build step. DOM is built with textContent, never
// innerHTML, so content shown here is never interpreted as markup.
"use strict";

const ZV = (window.ZV = { views: {}, session: null });

// -----------------------------------------------------------------
// dom
// -----------------------------------------------------------------

ZV.el = function el(tag, attrs, children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === "text") node.textContent = value;
    else if (key === "class") node.className = value;
    else if (key === "on") {
      for (const [ev, fn] of Object.entries(value)) node.addEventListener(ev, fn);
    } else if (key === "props") Object.assign(node, value);
    else if (value === true) node.setAttribute(key, "");
    else if (value !== false && value != null) node.setAttribute(key, value);
  }
  for (const child of [].concat(children || [])) {
    if (child == null || child === false) continue;
    node.append(typeof child === "string" ? document.createTextNode(child) : child);
  }
  return node;
};

const el = ZV.el;

ZV.button = function (label, onClick, cls, attrs) {
  return el("button", Object.assign({
    type: "button", class: "btn " + (cls || ""), on: { click: onClick },
  }, attrs || {}), label);
};

ZV.link = function (label, href, cls, attrs) {
  return el("a", Object.assign({ class: "btn " + (cls || ""), href }, attrs || {}), label);
};

/// Page frame: header with title, lead text and actions, then body.
ZV.page = function ({ title, lead, actions, back, wide }, body) {
  return el("div", { class: wide ? "page wide" : "page" }, [
    el("div", { class: "page-header" }, [
      el("div", { class: "titles" }, [
        back ? el("a", { class: "back", href: back.href }, ["← ", back.label]) : null,
        el("h1", { text: title }),
        lead ? el("p", { class: "lead" }, lead) : null,
      ]),
      actions ? el("div", { class: "actions" }, actions) : null,
    ]),
  ].concat(body || []));
};

ZV.show = function (nodes, narrow) {
  const main = document.getElementById("main");
  main.className = narrow ? "narrow" : "";
  main.replaceChildren(...[].concat(nodes));
};

ZV.field = function (label, input, hint) {
  if (!input.id) input.id = "f-" + Math.random().toString(36).slice(2, 9);
  return el("div", { class: "field" }, [
    el("label", { for: input.id, text: label }),
    input,
    hint ? el("p", { class: "hint" }, hint) : null,
  ]);
};

ZV.empty = function (title, text, action) {
  return el("div", { class: "empty" }, [
    el("h2", { text: title }), el("p", { text }), action || null,
  ]);
};

ZV.formatSize = function (bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + " KB";
  return (bytes / 1048576).toFixed(1) + " MB";
};

/// "My Post.HTML" -> "my-post"
ZV.slugify = function (name) {
  return name.toLowerCase()
    .normalize("NFKD").replace(/[̀-ͯ]/g, "")
    .replace(/\.(html?|md|markdown|css|js|xml)$/, "")
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^[^a-z0-9]+/, "")
    .replace(/-+$/, "")
    .slice(0, 64);
};

ZV.mediaName = function (name) {
  const dot = name.lastIndexOf(".");
  if (dot < 0) return ZV.slugify(name);
  return ZV.slugify(name.slice(0, dot)) + "." + name.slice(dot + 1).toLowerCase();
};

ZV.siteUrl = function (path) {
  const port = ZV.session ? ZV.session.public_port : 7080;
  return location.protocol + "//" + location.hostname + ":" + port + "/" + (path || "");
};

// -----------------------------------------------------------------
// api
// -----------------------------------------------------------------

const friendly = {
  Unauthorized: "Your session has ended. Please log in again.",
  Forbidden: "You are not allowed to do that.",
  PasswordChangeRequired: "Change the default password first.",
  NotFound: "That item no longer exists. It may have been deleted.",
  InvalidName: "Names may use lowercase letters, digits, - and _, " +
    "start with a letter or digit, and be at most 64 characters.",
  InvalidDate: "Dates must look like 2026-11-15.",
  InvalidKind: "The type must be \"post\" or \"page\".",
  InvalidFormat: "The format must be Markdown or HTML.",
  MissingSlug: "Give the entry a name (slug) first.",
  InvalidContent: "The file must be UTF-8 text.",
  TooLarge: "That is larger than the server allows.",
  ContentMismatch: "The file's contents don't match its extension.",
  UnsupportedMediaType: "That file type isn't supported.",
  QuotaExceeded: "Media storage is full. Delete some files first.",
  TooManyAttempts: "Too many failed attempts. Wait a few minutes.",
  RateLimited: "Too many requests at once. Wait a moment and retry.",
  WeakPassword: "Choose a longer password: at least 8 characters, " +
    "not \"admin\" and not your user name.",
  PasswordManagedByConfig: "The password is set in the server config.",
  TooManySnippets: "Too many snippets are enabled.",
  InvalidTitle: "The site title is too long or contains line breaks.",
};

const layoutErrors = /^(Xml|InvalidXml|UnknownLayout|MissingLayout|InvalidLayout|LayoutNeeds)/;

class ApiError extends Error {
  constructor(status, code) {
    let message = friendly[code];
    if (!message && layoutErrors.test(code)) {
      message = "The layout isn't valid (" + code + "). Nothing was saved.";
    }
    super(message || "Something went wrong (" + status + (code ? " " + code : "") + ").");
    this.status = status;
    this.code = code;
  }
}

ZV.api = async function api(method, path, body, query) {
  const options = {
    method,
    credentials: "same-origin",
    headers: { "X-Requested-With": "zerverg" },
  };
  if (body !== undefined) {
    if (body instanceof Blob) options.body = body;
    else if (typeof body === "string") {
      options.body = body;
      options.headers["Content-Type"] = "text/plain; charset=utf-8";
    } else {
      options.body = JSON.stringify(body);
      options.headers["Content-Type"] = "application/json";
    }
  }
  const qs = query ? "?" + new URLSearchParams(query) : "";
  let res;
  try {
    res = await fetch("/api/v1" + path + qs, options);
  } catch (_) {
    throw new ApiError(0, "Offline");
  }
  const type = res.headers.get("content-type") || "";
  const data = res.status === 204 ? null
    : type.startsWith("application/json") ? await res.json() : await res.text();
  if (res.ok) return data;
  const code = data && data.error ? data.error : res.statusText;
  if (res.status === 401 && ZV.session && ZV.session.authenticated) {
    ZV.session = null;
    ZV.refreshSession();
  }
  throw new ApiError(res.status, code);
};

friendly.Offline = "Can't reach the server. Check your connection.";

// -----------------------------------------------------------------
// messages
// -----------------------------------------------------------------

ZV.toast = function (message, kind) {
  const box = document.getElementById("toasts");
  const error = kind === "error";
  const close = ZV.button("Dismiss", () => toast.remove(), "ghost small");
  const toast = el("div", {
    class: "toast " + (kind || "ok"), role: error ? "alert" : "status",
  }, [el("div", { class: "message", text: message }), close]);
  box.append(toast);
  setTimeout(() => toast.remove(), error ? 12000 : 5000);
};

ZV.failed = (err) => ZV.toast(err.message, "error");

/// Disables `button` and shows progress until `promise` settles.
ZV.busy = async function (button, promise) {
  button.setAttribute("aria-busy", "true");
  button.disabled = true;
  try {
    return await promise;
  } finally {
    button.removeAttribute("aria-busy");
    button.disabled = false;
  }
};

// -----------------------------------------------------------------
// dialogs
// -----------------------------------------------------------------

function openDialog(build) {
  return new Promise((resolve) => {
    const dialog = el("dialog");
    const done = (value) => { dialog.close(); dialog.remove(); resolve(value); };
    dialog.addEventListener("cancel", (e) => { e.preventDefault(); done(null); });
    dialog.append(build(done));
    document.body.append(dialog);
    dialog.showModal();
  });
}

/// Resolves true when confirmed. `danger` styles the action red.
ZV.confirm = function ({ title, message, action, danger }) {
  return openDialog((done) => {
    const ok = el("button", {
      type: "submit", class: "btn " + (danger ? "danger solid" : "primary"),
    }, action || "Continue");
    return el("form", { method: "dialog", on: { submit: (e) => {
      e.preventDefault(); done(true);
    } } }, [
      el("h2", { text: title }),
      message ? el("p", { text: message }) : null,
      el("div", { class: "actions" }, [
        ZV.button("Cancel", () => done(false), "", { autofocus: true }), ok,
      ]),
    ]);
  }).then(Boolean);
};

/// Asks for one value; resolves null when cancelled. `check(value)`
/// returns an error message or "".
ZV.prompt = function ({ title, message, label, value, hint, action, check }) {
  return openDialog((done) => {
    const input = el("input", { type: "text", value: value || "", autocomplete: "off" });
    const error = el("p", { class: "field-error", hidden: true });
    const field = ZV.field(label, input, hint);
    field.append(error);
    setTimeout(() => input.select(), 0);
    return el("form", { method: "dialog", on: { submit: (e) => {
      e.preventDefault();
      const problem = check ? check(input.value) : "";
      input.setAttribute("aria-invalid", problem ? "true" : "false");
      error.hidden = !problem;
      error.textContent = problem;
      if (!problem) done(input.value);
    } } }, [
      el("h2", { text: title }),
      message ? el("p", { text: message }) : null,
      field,
      el("div", { class: "actions" }, [
        ZV.button("Cancel", () => done(null)),
        el("button", { type: "submit", class: "btn primary" }, action || "OK"),
      ]),
    ]);
  });
};

ZV.checkSlug = function (value) {
  return /^[a-z0-9][a-z0-9_-]{0,63}$/.test(value) ? "" : friendly.InvalidName;
};

/// Confirms, deletes, toasts, then runs `then`.
ZV.remove = async function (what, path, then) {
  const yes = await ZV.confirm({
    title: "Delete " + what + "?",
    message: "This can't be undone.",
    action: "Delete",
    danger: true,
  });
  if (!yes) return;
  try {
    await ZV.api("DELETE", path);
    ZV.toast("Deleted " + what + ".");
    then();
  } catch (err) {
    ZV.failed(err);
  }
};

// -----------------------------------------------------------------
// routing
// -----------------------------------------------------------------

/// A view with unsaved work sets ZV.unsaved to a function that
/// returns true while there are changes to lose.
ZV.unsaved = null;
let currentHash = location.hash;

const hasUnsaved = () => Boolean(ZV.unsaved && ZV.unsaved());

ZV.go = function (hash) {
  if (location.hash === hash) ZV.route();
  else location.hash = hash;
};

ZV.route = function () {
  const session = ZV.session;
  const signedIn = Boolean(session && session.authenticated);
  document.getElementById("topbar").hidden = !signedIn;
  document.getElementById("sidebar").hidden = !signedIn;
  document.getElementById("shell").classList.toggle("signed-out", !signedIn);
  ZV.unsaved = null;
  currentHash = location.hash;
  if (!signedIn) return loginView();
  fillUserBox(session);
  if (session.must_change_password) return forcedPasswordView();
  const parts = location.hash.replace(/^#\/?/, "").split("/").map(decodeURIComponent);
  const name = parts[0] || "posts";
  const view = ZV.views[name] || ZV.views.posts;
  markNav(ZV.views[name] ? name : "posts");
  view(...parts.slice(1));
  document.getElementById("main").focus({ preventScroll: true });
};

async function onHashChange() {
  if (hasUnsaved() && location.hash !== currentHash) {
    const target = location.hash;
    history.replaceState(null, "", currentHash);
    const leave = await ZV.confirm({
      title: "Leave without saving?",
      message: "Your unsaved changes will be lost.",
      action: "Leave",
      danger: true,
    });
    if (!leave) return;
    history.replaceState(null, "", target);
  }
  ZV.route();
}

function markNav(name) {
  for (const a of document.querySelectorAll(".nav-link")) {
    const on = a.getAttribute("href") === "#/" + name;
    if (on) a.setAttribute("aria-current", "page");
    else a.removeAttribute("aria-current");
  }
}

function fillUserBox(session) {
  document.getElementById("user-name").textContent = session.user;
  document.getElementById("avatar").textContent = (session.user || "?")[0];
  document.getElementById("site-link").href = ZV.siteUrl("");
}

ZV.refreshSession = async function () {
  ZV.session = await ZV.api("GET", "/auth/session");
  ZV.route();
};

// -----------------------------------------------------------------
// login and password
// -----------------------------------------------------------------

function authCard(title, children) {
  return el("div", { class: "card auth-card" }, [
    el("div", { class: "card-body" }, [
      el("div", { class: "brand" }, [
        el("span", { class: "brand-mark", "aria-hidden": "true", text: "z" }),
        el("span", {}, ["zerverg ", el("small", { text: "console" })]),
      ]),
      el("h1", { text: title }),
    ].concat(children)),
  ]);
}

function formError() {
  return el("p", { class: "callout error", role: "alert", hidden: true });
}

function showFormError(box, err) {
  box.textContent = err.message;
  box.hidden = false;
}

function loginView() {
  const method = ZV.session ? ZV.session.auth_method : "password";
  if (method === "oauth") return providerLoginView();
  if (method !== "password") {
    return ZV.show(authCard("Not signed in", [el("p", { class: "lead",
      text: "This console uses " + method + " authentication. " +
        "Reach it through your identity proxy." })]), true);
  }
  const user = el("input", { type: "text", autocomplete: "username", required: true });
  const pass = el("input", { type: "password", autocomplete: "current-password", required: true });
  const error = formError();
  const submit = el("button", { type: "submit", class: "btn primary" }, "Log in");
  const form = el("form", { on: { submit: async (e) => {
    e.preventDefault();
    error.hidden = true;
    try {
      await ZV.busy(submit, ZV.api("POST", "/auth/login",
        { username: user.value, password: pass.value }));
      await ZV.refreshSession();
    } catch (err) {
      showFormError(error, err.status === 401
        ? { message: "Wrong user name or password." } : err);
      pass.select();
    }
  } } }, [error, ZV.field("User name", user), ZV.field("Password", pass), submit]);
  ZV.show(authCard("Log in", [el("p", { class: "lead", text: "Manage your site." }), form]), true);
  user.focus();
}

// "Sign in with ...": plain links; the server does the redirects and
// sets the session cookie on the way back.
function providerLoginView() {
  const failedBefore = /error=/.test(location.hash);
  const buttons = (ZV.session.providers || []).map((p) => el("a", {
    class: "btn", href: "/api/v1/auth/oauth/" + encodeURIComponent(p.name) + "/start",
  }, "Continue with " + p.label));
  ZV.show(authCard("Sign in", [
    failedBefore ? el("p", { class: "callout", role: "alert", text: "Sign-in " +
      "failed. Your account may not be on this site's allowlist." }) : null,
  ].concat(buttons)), true);
}

function passwordForm(onDone) {
  const current = el("input", { type: "password", autocomplete: "current-password", required: true });
  const next = el("input", { type: "password", autocomplete: "new-password", required: true, minlength: "8" });
  const again = el("input", { type: "password", autocomplete: "new-password", required: true });
  const error = formError();
  const submit = el("button", { type: "submit", class: "btn primary" }, "Change password");
  return el("form", { on: { submit: async (e) => {
    e.preventDefault();
    error.hidden = true;
    if (next.value !== again.value) {
      return showFormError(error, { message: "The new passwords don't match." });
    }
    try {
      await ZV.busy(submit, ZV.api("POST", "/auth/password",
        { current_password: current.value, new_password: next.value }));
      ZV.toast("Password changed. Other sessions were logged out.");
      onDone();
    } catch (err) {
      showFormError(error, err);
    }
  } } }, [
    error,
    ZV.field("Current password", current),
    ZV.field("New password", next,
      "At least 8 characters; not \"admin\" and not the user name."),
    ZV.field("Repeat new password", again),
    submit,
  ]);
}

function forcedPasswordView() {
  document.getElementById("sidebar").hidden = true;
  document.getElementById("shell").classList.add("signed-out");
  ZV.show(authCard("Choose a new password", [
    el("p", { class: "callout", text: "This server still uses the factory " +
      "credentials (admin / admin). Pick your own password to continue." }),
    passwordForm(ZV.refreshSession),
  ]), true);
}

ZV.views.account = function accountView() {
  const s = ZV.session;
  const facts = el("dl", { class: "cheatsheet" }, [
    el("dt", { text: "User" }), el("dd", { text: s.user }),
    el("dt", { text: "Sign-in method" }), el("dd", { text: s.auth_method }),
    el("dt", { text: "Password source" }), el("dd", { text: s.password_source }),
  ]);
  let password;
  if (s.auth_method !== "password") {
    password = el("p", { class: "hint", text: "Passwords are not used " +
      "with this sign-in method." });
  } else if (s.password_source === "config") {
    password = el("p", { class: "hint", text: "The password is set in the " +
      "server configuration (admin_password_hash) and can't be changed here." });
  } else {
    password = passwordForm(ZV.refreshSession);
  }
  ZV.show(ZV.page({ title: "Account" }, [
    el("div", { class: "card" }, el("div", { class: "card-body" }, facts)),
    el("div", { class: "card" }, el("div", { class: "card-body" }, [
      el("h2", { text: "Password" }), password,
    ])),
  ]));
};

// -----------------------------------------------------------------
// light / dark
// -----------------------------------------------------------------

function currentTheme() {
  const chosen = document.documentElement.dataset.theme;
  if (chosen) return chosen;
  return matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function syncThemeToggle() {
  const button = document.getElementById("theme-toggle");
  const next = currentTheme() === "dark" ? "light" : "dark";
  button.textContent = next === "dark" ? "☾" : "☀";
  button.setAttribute("aria-label", "Switch to " + next + " theme");
  button.title = "Switch to " + next + " theme";
}

function toggleTheme() {
  const next = currentTheme() === "dark" ? "light" : "dark";
  document.documentElement.dataset.theme = next;
  try { localStorage.setItem("zv-console-theme", next); } catch (_) { /* ignore */ }
  syncThemeToggle();
}

// -----------------------------------------------------------------
// start
// -----------------------------------------------------------------

document.addEventListener("DOMContentLoaded", () => {
  syncThemeToggle();
  document.getElementById("theme-toggle").addEventListener("click", toggleTheme);
  matchMedia("(prefers-color-scheme: dark)").addEventListener("change", syncThemeToggle);
  document.getElementById("logout").addEventListener("click", async () => {
    try {
      await ZV.api("POST", "/auth/logout");
      history.replaceState(null, "", "#/");
      await ZV.refreshSession();
    } catch (err) {
      ZV.failed(err);
    }
  });
  window.addEventListener("hashchange", onHashChange);
  window.addEventListener("beforeunload", (e) => {
    if (hasUnsaved()) e.preventDefault();
  });
  ZV.refreshSession().catch(ZV.failed);
});
