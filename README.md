<div align="center">

<img src="src/defaults/media/zerverg-banner.svg" alt="ZERVERG" width="420">

<br><br>

<img src="src/defaults/media/zerverg-logo.svg" alt="" width="20"> &nbsp;
<code>// files in, website out.</code>

<br><br>

**[ [quick start](#-quick-start) ]** &nbsp;
**[ [how it works](#-how-it-works) ]** &nbsp;
**[ [api](#-api) ]** &nbsp;
**[ [hardening](#-hardening) ]** &nbsp;
**[ [license](#-license) ]**

<br>

![zig 0.16](https://img.shields.io/badge/zig-0.16-1c1e21?style=flat-square&labelColor=23262a&color=9ec29a)
![database: none](https://img.shields.io/badge/database-none-1c1e21?style=flat-square&labelColor=23262a&color=9ec29a)
![dependencies: 0](https://img.shields.io/badge/dependencies-0-1c1e21?style=flat-square&labelColor=23262a&color=9ec29a)
![license](https://img.shields.io/badge/license-Apache--2.0%20%2B%20Commons%20Clause-1c1e21?style=flat-square&labelColor=23262a&color=9ec29a)

</div>

---

```
~/zerverg $ cat README
```

**zerverg** is a small, database-free website engine written in Zig.
A website is four kinds of plain files, and nothing else:

| file     | decides                                  | lives in     |
| -------- | ---------------------------------------- | ------------ |
| `*.xml`  | the **shape**: header, sidebar, nav, footer | `layouts/`  |
| `*.css`  | the **look**: colours, fonts, borders    | `styles/`    |
| `*.html` | the **words**: posts and pages           | `posts/`     |
| `*.js`   | the **behaviour**: buttons, widgets      | `snippets/`  |

No database, no plugins, no in-browser editor. Write files with the
tools you like, push them through a REST API, roll back when you break
something.

<p align="center">
  <img src="docs/screenshot.png" alt="the default zerverg theme" width="760">
  <br>
  <sub><code>> the default theme, as seen on first boot</code></sub>
</p>

---

## ■ quick start

```console
$ zig build
$ ./zig-out/bin/zerverg serve --dev --data ./site
warning: DEVELOPMENT MODE: authentication is DISABLED.
info: fresh data directory: installing the default site
info: listening on http://127.0.0.1:7080
```

Open <http://127.0.0.1:7080>. The default site *is* the manual: its
`/docs` and `/api` pages document everything below in more detail.

> [!WARNING]
> `--dev` turns authentication **off** and binds to `127.0.0.1` only.
> Never expose a dev instance to a network you don't trust.

### for real

```console
$ printf '%s\n' 'my password' | ./zig-out/bin/zerverg hash-password
$argon2id$v=19$m=19456,t=2,p=1$...
$ sudo cp deploy/zerverg.example.zon /etc/zerverg/zerverg.zon   # paste the hash
$ ./zig-out/bin/zerverg serve
```

Secrets can also come from the environment
(`ZERVERG_ADMIN_PASSWORD_HASH`, `ZERVERG_DATA_DIR`, ...). Precedence:
defaults → config file → environment → command-line flags.

---

## ■ how it works

```
request ─► layout (xml) ─► <main/> ◄─ entry (html) ◄─ <zv-entries>, media:
                │                                      expanded on render
                ▼
           style (css) + snippets (js) ─► page
```

### data directory

```
/var/lib/zerverg/
├── layouts/<name>/<version>.xml + HEAD    versioned, rollback-able
├── styles/<name>/<version>.css  + HEAD
├── snippets/<name>/<version>.js + HEAD
├── posts/<slug>.html                      posts and pages
├── media/<file>                           images, video
└── site.json                              title, active layout/style/snippets
```

Back it up with `tar`. Version it with `git`. Every write is atomic.

### a layout

```xml
<layout kind="sidebar-right" favicon="media:logo.svg">
  <header>
    <logo src="media:logo.svg" size="48"/>
    <site-title/>
    <tagline>notes from the terminal</tagline>
    <nav><link href="/">home</link><page-links/></nav>
  </header>
  <main/>
  <sidebar>
    <section title="search"><search/></section>
    <section title="recent"><recent-posts count="5"/></section>
  </sidebar>
  <footer><text>(c) me</text></footer>
</layout>
```

Layouts are validated on upload against a fixed vocabulary; each
component renders with a `zv-*` class for the stylesheet to target.

### an entry

```html
<title>hello, world</title>
<meta name="zerverg:date" content="2026-11-15">
<meta name="zerverg:kind" content="post">      <!-- post | page -->
<meta name="zerverg:tags" content="zig,web">
<body>
  <p>Hi. <img src="media:cat.png" alt="a cat"></p>
</body>
```

The page with slug `index` is the home page.

---

## ■ api

Everything goes through `/api/v1`, with HTTP Basic auth or a session
cookie from `POST /auth/login`.

```console
$ curl -u admin:pw -X PUT --data-binary @hello.html \
       http://localhost:7080/api/v1/posts/hello
$ curl -u admin:pw -X PUT --data-binary @dark.css \
       http://localhost:7080/api/v1/styles/dark
$ curl -u admin:pw -X POST \
       "http://localhost:7080/api/v1/styles/dark/rollback?version=1"
```

| method | path | |
| --- | --- | --- |
| `POST` | `/auth/login` · `/auth/logout` | `GET /auth/session` is public |
| `GET` `POST` | `/posts` | list · create (slug from meta) |
| `GET` `PUT` `DELETE` | `/posts/:slug` | raw HTML |
| `GET` · `PUT` `DELETE` | `/media` · `/media/:file` | list · raw bytes |
| `GET` `PUT` | `/site` | title, active layout / style / snippets |
| `GET` | `/{layouts,styles,snippets}` | list with current version |
| `GET` `PUT` `DELETE` | `/{kind}/:name` | `?version=N` on `GET` |
| `GET` | `/{kind}/:name/versions` | |
| `POST` | `/{kind}/:name/rollback?version=N` | |

Cookie-authenticated writes must send `X-Requested-With: zerverg`.

---

## ■ hardening

On by default, tunable in the config file:

- **bodies** are read only *after* routing and authentication, capped
  per route; `max_body_bytes` (128 MiB) is the hard ceiling
- **rate limit** 20 req/s per client, bursts of 120; IPv6 grouped by /64
- **connections** 256 total, 16 per IP, 60 s lifetime, 1000 requests each
- **logins** argon2id, lockout after 5 failures, hashed session tokens,
  `HttpOnly` + `SameSite=Strict` cookies, CSRF header on writes
- **headers** CSP, nosniff, frame denial, referrer, permissions and
  cross-origin policies; HSTS + `Secure` cookies with `.https = true`
- **uploads** UTF-8 text only, layouts schema-validated, media checked
  against file signatures, scripted SVGs rejected, media streamed
- **paths** no dot segments or control bytes, 2 KiB max
- **audit** every admin change is logged as an `audit:` line

> [!NOTE]
> Behind a reverse proxy every client shares the proxy's IP. Raise the
> per-IP limits or set `rate_limit_per_s = 0`.

---

## ■ hacking

```console
$ zig build test
```

```
src/
├── main.zig  cli.zig  config.zig  routes.zig
├── http/      server, request, router, limits, headers
├── auth/      passwords, sessions, login lockout
├── store/     files, versioned libraries, posts, media
├── layout/    xml parser, schema, renderer
├── site/      public pages, search
├── api/       REST handlers
└── defaults/  the first-boot site
```

House rules: functions ≤ 60 lines, lines ≤ 80 columns, `zig fmt`.

**roadmap** `[ ]` admin web UI · `[ ]` native TLS · `[ ]` docker image

---

## ■ license

**Apache-2.0 with the Commons Clause.** See [`LICENSE`](LICENSE) and
[`NOTICE`](NOTICE).

| | |
| --- | --- |
| ✔ use it, including inside your business | ✔ read, modify, fork |
| ✔ redistribute it, modified or not | ✔ keep it free for others |
| ✘ sell it, or sell a modified version | ✘ sell hosting or support whose value is zerverg |
| ✎ keep the copyright and `NOTICE` | ✎ credit the original project |

This makes zerverg *source-available*, not OSI open source: the
no-selling condition is the one thing those licenses cannot include.

<div align="center">
<br>
<code>powered by zerverg :: no database was harmed</code>
</div>
