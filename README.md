# zerverg

A small, database-free website engine written in Zig.

- **XML** layouts define page structure
- **CSS** styles define the look
- **HTML** files are the content (posts and pages)
- **JS** snippets add behaviour

All content lives on the filesystem under the data directory
(default `/var/lib/zerverg`); there is no database.

## Quick start

```sh
zig build
./zig-out/bin/zerverg serve --dev --data ./site   # NO AUTH, 127.0.0.1
```

Production:

```sh
printf '%s\n' 'my password' | ./zig-out/bin/zerverg hash-password
# put the hash in /etc/zerverg/zerverg.zon (see deploy/), then:
./zig-out/bin/zerverg serve
```

## Content metadata

Uploaded HTML carries its metadata in meta tags:

```html
<title>My post</title>
<meta name="zerverg:slug" content="my-post">     <!-- for POST uploads -->
<meta name="zerverg:date" content="2026-11-15">
<meta name="zerverg:kind" content="post">        <!-- post | page -->
<meta name="zerverg:layout" content="wide">      <!-- optional -->
<meta name="zerverg:tags" content="zig,web">
```

Reference media as `src="media:cat.png"`; it is rewritten to the media
endpoint on render.

## REST API (`/api/v1`)

Authenticate with the session cookie from `POST /auth/login`, or with
HTTP Basic auth. Cookie-authenticated writes must send
`X-Requested-With: zerverg`.

| Method | Path | |
|---|---|---|
| POST | `/auth/login` | `{"username","password"}` → session cookie |
| POST | `/auth/logout` | |
| GET | `/auth/session` | public |
| GET / POST | `/posts` | list / create (slug from meta) |
| GET / PUT / DELETE | `/posts/:slug` | raw HTML body |
| GET | `/media` | list |
| PUT / DELETE | `/media/:name` | raw file body |
| GET / PUT | `/site` | title, active layout/style, snippets |
| GET | `/{layouts,styles,snippets}` | list with current version |
| GET / PUT / DELETE | `/{kind}/:name` | `?version=N` on GET |
| GET | `/{kind}/:name/versions` | |
| POST | `/{kind}/:name/rollback?version=N` | |

```sh
curl -u admin:pw -X PUT --data-binary @dark.css \
     http://localhost:7080/api/v1/styles/dark
```

## Default site

A fresh data directory is seeded with a default layout, theme, snippet,
home page, docs and API reference (`src/defaults/`). Once `site.json`
exists it is never re-seeded. The running site's `/docs` and `/api`
pages are the full manual.

## Hardening (defaults)

- Bodies are only read after routing and authentication, with
  per-route caps; `max_body_bytes` (128 MiB) is the hard ceiling.
- Per-IP rate limit (20 req/s, burst 120), 16 connections per IP,
  256 total, 60 s connection lifetime, 1000 requests per connection.
  IPv6 clients are grouped by /64.
- Login lockout after 5 failures; argon2id hashes; hashed session
  tokens; CSRF header on cookie-authenticated writes.
- CSP, nosniff, frame denial, referrer, permissions and cross-origin
  policies on every response; HSTS + Secure cookies with `https`.
- Uploads: UTF-8 text only, layouts schema-validated, media checked
  against file signatures, scripted SVGs rejected; media streamed.
- Strict request paths (no dot segments, control bytes, 2 KiB max).
- Admin changes are logged as `audit:` lines.

## Development

```sh
zig build test
```

Code rules: functions ≤ 60 lines, lines ≤ 80 columns, `zig fmt`.
