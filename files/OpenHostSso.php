<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use App\Models\User;

/**
 * OpenHost single-sign-on middleware.
 *
 * When the OpenHost router verifies an instance owner's zone_auth cookie it
 * stamps the request with `X-OpenHost-Is-Owner: true`. The in-container
 * auth-proxy forwards that header (and strips any client-supplied copy of it)
 * so it can be trusted here.
 *
 * On an owner navigation to an admin/studio path, if the visitor does not yet
 * have an authenticated LinkStack session, we log them in directly as the
 * bootstrapped admin user. This mirrors the native installer `/skip` route,
 * which calls `Auth::login()` on the seeded admin. No password is ever read,
 * transmitted, or stored on disk.
 *
 * Anonymous visitors (no owner header) are never affected, so public link
 * pages keep working without OpenHost auth.
 */
class OpenHostSso
{
    /**
     * Path prefixes that are publicly shareable and must NEVER trigger an
     * owner auto-login. These mirror routing.public_paths in openhost.toml.
     */
    private const PUBLIC_PREFIXES = [
        'p/',         // /p/{handle} – a user's public link page (canonical;
                      //   custom_url_prefix is set to "p/" so the page lives
                      //   under a slash-terminated path the OpenHost router can
                      //   match as a public prefix)
        '@',          // /@handle  – LinkStack's built-in (non-prefixed) page URL
        'u/',         // /u/{id}   – numeric user redirect
        'theme/',     // /theme/@handle – public theme asset
        'vcard/',     // /vcard/{id} – downloadable vCard
        'going/',     // /going/{id} – outbound click counter
        'info/',      // /info/{id} – redirect info
        'pages/',     // /pages/terms|privacy|contact – public info pages
        'report',     // public report form
        'demo-page',  // public demo
        'block-asset/',
        'css/', 'js/', 'img/', 'images/', 'fonts/', 'assets/', 'themes/',
        'storage/', 'favicon', 'robots.txt', 'apple-touch-icon',
        'social-auth/',
    ];

    public function handle(Request $request, Closure $next)
    {
        if ($this->shouldAutoLogin($request)) {
            $admin = User::where('role', 'admin')->orderBy('id')->first();
            if ($admin) {
                Auth::login($admin);
                $request->session()->regenerate();
            }
        }

        return $next($request);
    }

    private function shouldAutoLogin(Request $request): bool
    {
        // Only act on the trusted owner header set by the auth-proxy.
        if (strtolower((string) $request->header('X-OpenHost-Is-Owner')) !== 'true') {
            return false;
        }

        // Already signed in – nothing to do.
        if (Auth::check()) {
            return false;
        }

        // Only auto-login on real HTML navigations, not asset/XHR fetches.
        if (! $request->isMethod('GET')) {
            return false;
        }
        if (strpos((string) $request->header('Accept'), 'text/html') === false) {
            return false;
        }

        // Never auto-login on a publicly shareable path.
        $path = ltrim($request->path(), '/');
        if ($path === '' ) {
            // Do NOT auto-login at the site root. The root renders LinkStack's
            // home / the owner's own link page, which we want to show as-is.
            // The root is NOT in public_paths, so the OpenHost router still
            // gates it behind zone_auth (only the owner reaches it); the owner
            // opens the admin panel via /dashboard, where auto-login fires.
            return false;
        }
        foreach (self::PUBLIC_PREFIXES as $prefix) {
            if (strncmp($path, $prefix, strlen($prefix)) === 0) {
                return false;
            }
        }

        // Don't fight Laravel's guest-only auth routes.
        if (in_array($path, ['login', 'register', 'forgot-password'], true)) {
            return false;
        }

        return true;
    }
}
