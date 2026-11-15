# zerverg

A small, database-free website engine written in Zig.

- **XML** layouts define page structure *(layout engine: next milestone)*
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

## Development

```sh
zig build test
```

Code rules: functions ≤ 60 lines, lines ≤ 80 columns, `zig fmt`.
