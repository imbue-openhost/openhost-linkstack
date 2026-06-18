# openhost-linkstack

[LinkStack](https://github.com/LinkStackOrg/LinkStack) — an open-source,
self-hosted Linktree alternative — packaged as an OpenHost app with one-click
owner SSO and public link-page passthrough.

## What you get

- The full LinkStack admin panel, auto-logged-in for the OpenHost instance
  owner. No LinkStack username/password to manage.
- Public link pages reachable by anyone without OpenHost login — exactly what a
  Linktree-style page is for. The shareable URL is **`/p/<handle>`** (e.g.
  `/p/admin`), plus vCards (`/vcard/...`), themed pages, and outbound click
  links (`/going/...`). See "Public-page passthrough" below for why the site
  root `/` is deliberately gated and `/@handle` is not the public URL here.
- SQLite storage, persisted across restarts in the app's OpenHost data dir.

## How auth works

This app uses an adapted **trusted-header SSO** pattern (Pattern A).

1. When the OpenHost router verifies the owner's `zone_auth` cookie it stamps
   the upstream request with `X-OpenHost-Is-Owner: true`.
2. An in-container Python auth-proxy (`auth_proxy.py`, listening on the
   OpenHost-routed `:8080`) sanitises that header — stripping any
   client-supplied copy and re-adding it only when the router set it — then
   forwards to Apache/LinkStack on `:8081`. It also rewrites `Host` from
   `X-Forwarded-Host` and forces `X-Forwarded-Proto: https`.
3. A LinkStack-native middleware (`app/Http/Middleware/OpenHostSso.php`) reads
   the trusted header and, on an owner navigation to an admin/studio path with
   no existing session, logs the visitor in as the seeded `admin` user via
   Laravel's `Auth::login()` — the same call LinkStack's own installer
   `/skip` route makes. `start.sh` registers this middleware in the kernel's
   `$middlewarePriority` ahead of `Authenticate`, so the auto-login runs before
   the `auth` gate evaluates the session.

**No password is ever generated, transmitted, or written to disk.** The owner
header alone drives the auto-login, so nothing in the app's data dir is a
usable credential. Anonymous visitors (no owner header) are never
auto-logged-in, which is what keeps public link pages working.

LinkStack's `AdminSeeder` ships the admin with the well-known default password
`12345678`, and the `/login` form is publicly reachable. To close that hole,
`start.sh` rotates every user's password to a fresh random value (bcrypt hash
only, never plaintext) on each boot and disables self-registration. The owner
never needs the password — SSO is the only login path.

## Public-page passthrough

A user's public link page is served at **`/p/<handle>`** (e.g. `/p/admin`).
LinkStack normally serves pages at `/@<handle>`, but the OpenHost router's
public-path matcher only matches slash-terminated prefixes — it cannot match
`/@handle` from a `/@` entry. `start.sh` therefore sets LinkStack's
`custom_url_prefix` to `p/` so the canonical public URL (`/p/<handle>`) lives
under a matchable prefix. The site root `/` is intentionally NOT public: listing
`/` in `public_paths` would make the entire app (including `/dashboard`) public
and stop the router from ever stamping the owner header, breaking SSO.

The public-share path prefixes are declared in two places that must stay in
sync:

- `routing.public_paths` in `openhost.toml` (the OpenHost router allow-list).
- `PUBLIC_PREFIXES` in `app/Http/Middleware/OpenHostSso.php` (so the owner is
  not auto-logged-in while viewing a public page).

## Persistence

`start.sh` relocates LinkStack's writable state — `database/` (SQLite),
`storage/`, `config/`, uploaded `themes/`, and `assets/img/` (avatars and
backgrounds) — plus `.env` into `$OPENHOST_APP_DATA_DIR` and symlinks them back
into `/htdocs`. First boot generates an `APP_KEY`, configures SQLite, runs the
migrations + seeders, and marks the install complete via its own
`.openhost_installed` marker (independent of LinkStack's shipped `ISINSTALLED`).

Apache runs as the unprivileged `apache` user on port `8081` (it cannot bind
`:80`/`:443`); the SSL vhost is disabled since OpenHost terminates TLS upstream.

## Layout

```
Dockerfile                       base off linkstackorg/linkstack + python3
openhost.toml                    OpenHost manifest
start.sh                         first-boot install + supervisor
auth_proxy.py                    SSO sidecar on :8080
files/OpenHostSso.php            LinkStack auto-login middleware
```

## License

LinkStack is AGPL-3.0. This packaging is provided under the same terms; see the
upstream project for details.
