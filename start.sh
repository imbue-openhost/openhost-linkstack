#!/bin/bash
# OpenHost supervisor for LinkStack.
#
#   1. Wire LinkStack's writable state to the persistent OpenHost data dir.
#   2. First-boot install: APP_KEY, SQLite DB, migrate + seed, mark installed.
#   3. Install the OpenHost SSO middleware (owner auto-login, no creds on disk).
#   4. Run Apache (as the unprivileged apache user) + the auth-proxy sidecar.
set -euo pipefail

APP_DIR=/htdocs
DATA_DIR="${OPENHOST_APP_DATA_DIR:-/data/app_data/linkstack}"
ZONE="${OPENHOST_ZONE_DOMAIN:-localhost}"
APP_NAME="${OPENHOST_APP_NAME:-linkstack}"
APP_URL="https://${APP_NAME}.${ZONE}"
APACHE_USER=apache
APACHE_GROUP=apache

log() { echo "[start] $*"; }

mkdir -p "$DATA_DIR"

# ---------------------------------------------------------------------------
# 1. Persistent state.
#
# Every directory/file LinkStack writes at runtime is relocated into the
# persistent data dir and symlinked back into /htdocs. On first boot we seed
# the data dir from the image's shipped copy.
# ---------------------------------------------------------------------------
# dirs (relative to /htdocs) that must persist
PERSIST_DIRS=(
  "database"
  "storage"
  "config"
  "themes"
  "assets/img"
)
# single files that must persist
PERSIST_FILES=(
  ".env"
)

link_path() {
  # $1 = path relative to /htdocs
  local rel="$1"
  local src="$APP_DIR/$rel"
  local dst="$DATA_DIR/$rel"

  # Already a symlink pointing at the correct data-dir target? nothing to do.
  # If it is a symlink to the WRONG place, repair it below.
  if [ -L "$src" ]; then
    if [ "$(readlink -f "$src")" = "$(readlink -f "$dst")" ]; then
      return 0
    fi
    rm -f "$src"
  fi

  mkdir -p "$(dirname "$dst")"
  if [ ! -e "$dst" ]; then
    if [ -e "$src" ]; then
      cp -a "$src" "$dst"
    fi
  fi
  rm -rf "$src"
  mkdir -p "$(dirname "$src")"
  ln -s "$dst" "$src"
}

for d in "${PERSIST_DIRS[@]}"; do
  link_path "$d"
done

# .env: seed from .env.example on first boot if neither exists.
if [ ! -e "$DATA_DIR/.env" ]; then
  if [ -e "$APP_DIR/.env" ] && [ ! -L "$APP_DIR/.env" ]; then
    cp -a "$APP_DIR/.env" "$DATA_DIR/.env"
  elif [ -e "$APP_DIR/.env.example" ]; then
    cp -a "$APP_DIR/.env.example" "$DATA_DIR/.env"
  else
    : > "$DATA_DIR/.env"
  fi
fi
rm -f "$APP_DIR/.env"
ln -s "$DATA_DIR/.env" "$APP_DIR/.env"

# ---------------------------------------------------------------------------
# Helpers for editing the .env (operates on the real file in the data dir).
# ---------------------------------------------------------------------------
ENV_FILE="$DATA_DIR/.env"

set_env() {
  local key="$1" val="$2"
  # Guarantee the file exists so neither grep nor the editor can trip over a
  # missing path.
  [ -f "$ENV_FILE" ] || : > "$ENV_FILE"
  if grep -qE "^${key}=" "$ENV_FILE" 2>/dev/null; then
    # Replace the matching line in place. Abort hard on failure: a corrupt or
    # unwritable .env would break the whole deployment, so we must not continue
    # as if the setting were applied.
    if ! python3 - "$ENV_FILE" "$key" "$val" <<'PY'
import sys
path, key, val = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
with open(path) as fh:
    for line in fh:
        if line.split("=", 1)[0] == key:
            lines.append(f"{key}={val}\n")
        else:
            lines.append(line)
with open(path, "w") as fh:
    fh.writelines(lines)
PY
    then
      log "FATAL: failed to set ${key} in ${ENV_FILE}"
      exit 1
    fi
  else
    if ! printf '%s=%s\n' "$key" "$val" >> "$ENV_FILE"; then
      log "FATAL: failed to append ${key} to ${ENV_FILE}"
      exit 1
    fi
  fi
}

# ---------------------------------------------------------------------------
# 2. First-boot install.
# ---------------------------------------------------------------------------
DB_FILE="$DATA_DIR/database/database.sqlite"
mkdir -p "$DATA_DIR/database"

# Always (re)assert the deployment-specific settings.
set_env "DB_CONNECTION" "sqlite"
set_env "DB_DATABASE" "$DB_FILE"
set_env "APP_URL" "$APP_URL"
set_env "APP_ENV" "production"
set_env "APP_DEBUG" "false"
set_env "SESSION_DRIVER" "file"
# Explicitly DISABLE both HTTPS-redirect knobs. LinkStack's Headers middleware
# redirects to https based on $_SERVER['HTTPS'], which is unset because the
# auth-proxy speaks plain HTTP to Apache — leaving these on would cause an
# infinite redirect loop. We convey https to Laravel via X-Forwarded-Proto and
# the TrustProxies patch below instead.
set_env "FORCE_HTTPS" "false"
set_env "FORCE_ROUTE_HTTPS" "false"
set_env "ASSET_URL" "$APP_URL"

# Generate an APP_KEY if absent.
if ! grep -qE '^APP_KEY=base64:' "$ENV_FILE" 2>/dev/null; then
  set_env "APP_KEY" ""
  ( cd "$APP_DIR" && php artisan key:generate --force ) || true
fi

# SQLite file must exist before migrating.
[ -f "$DB_FILE" ] || : > "$DB_FILE"

# First-boot detection uses our OWN marker in the data dir, NOT LinkStack's
# storage/app/ISINSTALLED. The upstream release image ships ISINSTALLED already
# (so the app skips the install wizard), which would otherwise make us wrongly
# think the DB was migrated + the admin user seeded.
OH_INSTALL_MARKER="$DATA_DIR/.openhost_installed"
FIRST_BOOT=0
if [ ! -f "$OH_INSTALL_MARKER" ]; then
  FIRST_BOOT=1
fi

# Clear any leftover installer markers so the app is never stuck in the wizard,
# and ensure LinkStack itself considers the app installed (routes/web.php gates
# the whole app on storage/app/ISINSTALLED).
rm -f "$APP_DIR/INSTALLING" "$APP_DIR/INSTALLERLOCK" || true
mkdir -p "$DATA_DIR/storage/app"
: > "$DATA_DIR/storage/app/ISINSTALLED"

# Make sure the advanced-config exists (web.php copies it only inside the
# installed branch; do it here so it is present immediately).
if [ ! -f "$DATA_DIR/config/advanced-config.php" ] && \
   [ -f "$DATA_DIR/storage/templates/advanced-config.php" ]; then
  cp -a "$DATA_DIR/storage/templates/advanced-config.php" \
        "$DATA_DIR/config/advanced-config.php" || true
fi

# Set the public link-page URL prefix to "p/" so a user's public page is served
# at /p/<handle>. The OpenHost router's public-path matcher only matches
# slash-terminated prefixes, so a slash-terminated prefix lets /p/<handle> be
# reached by anonymous visitors (a bare "@" prefix could not be matched). We
# rewrite the value idempotently on every boot.
ADV_CONFIG="$DATA_DIR/config/advanced-config.php"
if [ -f "$ADV_CONFIG" ]; then
  python3 - "$ADV_CONFIG" <<'PY' || true
import re, sys
path = sys.argv[1]
src = open(path).read()
# Replace the custom_url_prefix value (any current quoted value) with 'p/'.
new, n = re.subn(
    r"(['\"]custom_url_prefix['\"]\s*=>\s*)['\"][^'\"]*['\"]",
    r"\1'p/'",
    src,
    count=1,
)
if n:
    open(path, "w").write(new)
PY
fi

# Run an artisan command, returning its exit status and logging on failure.
# Non-fatal: callers decide what to do, but failures are never swallowed
# silently.
run_artisan() {
  if ( cd "$APP_DIR" && php artisan "$@" ); then
    return 0
  fi
  log "WARNING: 'php artisan $*' failed (exit $?)"
  return 1
}

if [ "$FIRST_BOOT" = "1" ]; then
  log "first boot: migrating + seeding LinkStack"
  install_ok=1
  run_artisan migrate --force || install_ok=0
  run_artisan db:seed --force || install_ok=0
  run_artisan db:seed --class=PageSeeder --force || true
  run_artisan db:seed --class=ButtonSeeder --force || true
  # Ensure an admin user exists (AdminSeeder creates "admin"). This must
  # succeed for owner SSO to work.
  run_artisan db:seed --class=AdminSeeder --force || install_ok=0

  if [ "$install_ok" = "1" ]; then
    : > "$OH_INSTALL_MARKER"
    log "first boot complete"
  else
    # Do NOT mark the install complete; the next boot will retry rather than
    # leaving a half-installed instance that masquerades as ready.
    log "ERROR: first-boot install incomplete; will retry on next start"
  fi
else
  # Apply any pending migrations from image upgrades.
  run_artisan migrate --force || true
fi

# ---------------------------------------------------------------------------
# Security hardening (runs every boot — MUST succeed before we serve traffic).
#
# The AdminSeeder seeds the admin with a well-known default password
# ('12345678'). Because the owner authenticates exclusively via OpenHost SSO
# (trusted header), that password is never needed — but LinkStack's /login form
# is publicly reachable, so a known default would let ANYONE log in as admin.
# We rotate every user's password to a fresh strong random value, then VERIFY
# the default no longer authenticates. The plaintext is generated in memory and
# discarded; only the bcrypt hash is written to the DB. Nothing usable lands on
# disk.
#
# This is a hard gate: if rotation/verification fails we must NOT start Apache,
# otherwise the publicly-reachable /login form would accept the default
# credentials. Exiting non-zero makes OpenHost restart the container and retry.
# ---------------------------------------------------------------------------
HARDEN_PHP='foreach (\App\Models\User::all() as $u) {
    $u->password = \Illuminate\Support\Facades\Hash::make(bin2hex(random_bytes(32)));
    $u->save();
}
$bad = 0;
foreach (\App\Models\User::all() as $u) {
    if (\Illuminate\Support\Facades\Hash::check("12345678", $u->password)) { $bad++; }
}
if ($bad > 0) { throw new \Exception("default password still valid for $bad user(s)"); }
echo "ROTATE_OK\n";'
if ( cd "$APP_DIR" && printf '%s' "$HARDEN_PHP" | php artisan tinker --no-ansi 2>&1 ) | grep -q "ROTATE_OK"; then
  log "rotated + verified all user passwords (owner uses SSO; default rejected)"
else
  log "FATAL: could not rotate/verify admin password; refusing to start so the"
  log "       public /login form cannot accept the default credentials."
  exit 1
fi

# Disable public self-registration: this is a single-tenant owner deployment.
set_env "ALLOW_REGISTRATION" "false"

# ---------------------------------------------------------------------------
# 3. Install the OpenHost SSO middleware + register it in the HTTP kernel.
# ---------------------------------------------------------------------------
install -m 0644 /opt/openhost/OpenHostSso.php \
  "$APP_DIR/app/Http/Middleware/OpenHostSso.php"

KERNEL="$APP_DIR/app/Http/Kernel.php"
if [ -f "$KERNEL" ] && ! grep -q "OpenHostSso" "$KERNEL"; then
  python3 - "$KERNEL" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()

# 1) Add OpenHostSso to the 'web' group, immediately AFTER StartSession so the
#    session is initialised before we attempt Auth::login().
start_session = "\\Illuminate\\Session\\Middleware\\StartSession::class,"
inject = start_session + "\n            \\App\\Http\\Middleware\\OpenHostSso::class,"
assert start_session in src, "StartSession not found in Kernel"
src = src.replace(start_session, inject, 1)

# 2) Define an explicit $middlewarePriority so OpenHostSso runs BEFORE the
#    Authenticate middleware. Laravel sorts middleware that appear in this list
#    by this order regardless of group order; the 'auth' route middleware
#    (Illuminate\Auth\Middleware\Authenticate, which LinkStack's Authenticate
#    extends) is priority-sorted, so without listing OpenHostSso ahead of it our
#    auto-login would run too late and 'auth' would already have redirected.
priority_block = '''
    /**
     * The priority-sorted list of middleware (injected for OpenHost SSO).
     *
     * Forces OpenHostSso to run before authentication so owner auto-login
     * happens before the 'auth' middleware evaluates the session.
     *
     * @var array
     */
    protected $middlewarePriority = [
        \\Illuminate\\Foundation\\Http\\Middleware\\HandlePrecognitiveRequests::class,
        \\Illuminate\\Cookie\\Middleware\\EncryptCookies::class,
        \\Illuminate\\Cookie\\Middleware\\AddQueuedCookiesToResponse::class,
        \\Illuminate\\Session\\Middleware\\StartSession::class,
        \\Illuminate\\View\\Middleware\\ShareErrorsFromSession::class,
        \\App\\Http\\Middleware\\OpenHostSso::class,
        \\Illuminate\\Contracts\\Auth\\Middleware\\AuthenticatesRequests::class,
        \\Illuminate\\Routing\\Middleware\\ThrottleRequests::class,
        \\Illuminate\\Routing\\Middleware\\ThrottleRequestsWithRedis::class,
        \\Illuminate\\Contracts\\Session\\Middleware\\AuthenticatesSessions::class,
        \\Illuminate\\Routing\\Middleware\\SubstituteBindings::class,
        \\Illuminate\\Auth\\Middleware\\Authorize::class,
    ];
'''
# Insert the property right after the class opening brace.
marker = "class Kernel extends HttpKernel\n{"
assert marker in src, "Kernel class declaration not found"
src = src.replace(marker, marker + priority_block, 1)

open(path, "w").write(src)
PY
  log "registered OpenHostSso middleware (with priority)"
fi

# Trust the auth-proxy so X-Forwarded-Proto: https is honoured (otherwise
# Laravel generates http:// URLs and the owner's session cookie may not be
# marked secure). Apache only ever receives traffic from the in-container
# auth-proxy (it is not published outside the container; OpenHost routes solely
# to the proxy's :8080), so trusting all forwarding proxies ('*') is safe here.
TRUSTPROXIES="$APP_DIR/app/Http/Middleware/TrustProxies.php"
if [ -f "$TRUSTPROXIES" ] && grep -q 'protected \$proxies;' "$TRUSTPROXIES"; then
  python3 - "$TRUSTPROXIES" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
src = src.replace("protected $proxies;", "protected $proxies = '*';", 1)
open(path, "w").write(src)
PY
  log "patched TrustProxies to trust the loopback auth-proxy"
fi

# Fix broken Font Awesome icon/webfont URLs on public link pages.
#
# The public page template inlines assets/external-dependencies/fontawesome.css,
# which references its webfonts with the *relative* URL `url(assets/webfonts/…)`.
# On a normal LinkStack install pages live at /@<handle> (directory "/"), so the
# browser resolves that to /assets/webfonts/… and it works. Here pages live at
# /p/<handle> (directory "/p/"), so the browser resolves it to
# /p/assets/webfonts/… → 404, and every Font Awesome icon on a public page
# breaks. We rewrite those references to be root-relative (/assets/webfonts/…)
# so they resolve correctly regardless of the page's path depth. Idempotent.
for BLADE in \
  "$APP_DIR/resources/views/linkstack/modules/assets.blade.php" \
  "$APP_DIR/resources/views/demo.blade.php"; do
  # Apply only if the original str_replace() line is still present (idempotent:
  # once rewritten the original literal is gone, so re-runs are a no-op).
  if [ -f "$BLADE" ] && \
     grep -qF "str_replace('../', 'studio/', file_get_contents(base_path(\"assets/external-dependencies/fontawesome.css\")))" "$BLADE" 2>/dev/null; then
    # Extend the existing str_replace() that already rewrites '../' so it also
    # absolutises the webfont URLs. Matching the literal source line keeps this
    # surgical and a no-op once applied.
    if python3 - "$BLADE" <<'PY'
import sys
path = sys.argv[1]
src = open(path).read()
old = "str_replace('../', 'studio/', file_get_contents(base_path(\"assets/external-dependencies/fontawesome.css\")))"
new = ("str_replace(['../', 'url(assets/webfonts/'], "
       "['studio/', 'url(/assets/webfonts/'], "
       "file_get_contents(base_path(\"assets/external-dependencies/fontawesome.css\")))")
if old not in src:
    sys.exit(3)
src = src.replace(old, new)
open(path, "w").write(src)
PY
    then
      log "patched Font Awesome webfont URLs in $(basename "$BLADE")"
    else
      # Non-fatal (icons would still partially work via cached fonts), but the
      # operator must know the public-page Font Awesome fix did not apply.
      log "WARNING: failed to patch Font Awesome webfont URLs in $(basename "$BLADE")"
    fi
  fi
done

# Clear ALL caches AFTER patching the kernel/middleware. The upstream release
# image ships a cached route table (bootstrap/cache/routes.php) that serialises
# the middleware stack at build time — without clearing it, our newly-registered
# OpenHostSso middleware would never run on cached routes. Remove the cache
# files directly (belt-and-suspenders) and then run the artisan clears.
rm -f "$APP_DIR/bootstrap/cache/routes.php" \
      "$APP_DIR/bootstrap/cache/config.php" \
      "$APP_DIR/bootstrap/cache/services.php" \
      "$APP_DIR/bootstrap/cache/packages.php" 2>/dev/null || true
run_artisan config:clear || true
run_artisan route:clear || true
run_artisan view:clear || true

# ---------------------------------------------------------------------------
# 4. Ownership + launch.
# ---------------------------------------------------------------------------
# Apache runs as the apache user; it must own the persistent data + app tree.
chown -R "$APACHE_USER:$APACHE_GROUP" "$DATA_DIR" 2>/dev/null || true
chown -R "$APACHE_USER:$APACHE_GROUP" "$APP_DIR" 2>/dev/null || true

# Apache PID file lives in /htdocs per the upstream config; clear stale one.
rm -f "$APP_DIR/httpd.pid" || true

export HTTP_SERVER_NAME="${APP_NAME}.${ZONE}"
export HTTPS_SERVER_NAME="${APP_NAME}.${ZONE}"
export SERVER_ADMIN="admin@${ZONE}"
# The upstream httpd.conf references these env vars (normally set by the image's
# docker-entrypoint.sh, which we bypass). Without LOG_LEVEL defined, Apache
# fails to parse its config and exits, so we MUST export them here.
export LOG_LEVEL="${LOG_LEVEL:-info}"
export TZ="${TZ:-UTC}"
export PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-256M}"
export UPLOAD_MAX_FILESIZE="${UPLOAD_MAX_FILESIZE:-16M}"

# Preserve the upload / memory tuning the upstream entrypoint would have applied
# (we bypass docker-entrypoint.sh by setting our own ENTRYPOINT). We write our
# own dedicated ini and OVERWRITE it each boot, so values never accumulate /
# duplicate across restarts.
PHP_CUSTOM_INI=/etc/php83/conf.d/45-openhost.ini
if [ -w "$(dirname "$PHP_CUSTOM_INI")" ] 2>/dev/null; then
  cat > "$PHP_CUSTOM_INI" <<EOF 2>/dev/null || true
upload_max_filesize = ${UPLOAD_MAX_FILESIZE:-16M}
post_max_size = ${UPLOAD_MAX_FILESIZE:-16M}
memory_limit = ${PHP_MEMORY_LIMIT:-256M}
date.timezone = ${TZ:-UTC}
EOF
fi

# Apache runs as the unprivileged "apache" user, which cannot bind to ports
# <1024. OpenHost terminates TLS and routes plain HTTP to our auth-proxy, so we
# move Apache to an unprivileged port (8081) and disable the SSL vhost (which
# would otherwise try to bind privileged :443).
APACHE_PORT=8081
HTTPD_CONF=/etc/apache2/httpd.conf
SSL_CONF=/etc/apache2/conf.d/ssl.conf
if [ -w "$HTTPD_CONF" ]; then
  sed -i -E "s/^Listen[[:space:]]+80\$/Listen ${APACHE_PORT}/" "$HTTPD_CONF"
fi
# Neutralise the SSL config so Apache does not attempt to bind :443.
if [ -f "$SSL_CONF" ]; then
  mv -f "$SSL_CONF" "${SSL_CONF}.disabled" 2>/dev/null || : > "$SSL_CONF"
fi

cleanup() {
  log "shutting down"
  [ -n "${HTTPD_PID:-}" ] && kill "$HTTPD_PID" 2>/dev/null || true
  [ -n "${PROXY_PID:-}" ] && kill "$PROXY_PID" 2>/dev/null || true
}
trap cleanup TERM INT

log "starting Apache (as ${APACHE_USER}) on :${APACHE_PORT}"
su-exec "$APACHE_USER:$APACHE_GROUP" httpd -D FOREGROUND &
HTTPD_PID=$!

log "starting auth-proxy on :8080"
OPENHOST_PROXY_PORT=8080 UPSTREAM_HOST=127.0.0.1 UPSTREAM_PORT="${APACHE_PORT}" \
  python3 /opt/openhost/auth_proxy.py &
PROXY_PID=$!

# If either dies, tear down the other so OpenHost restarts the container.
wait -n "$HTTPD_PID" "$PROXY_PID"
cleanup
wait || true
