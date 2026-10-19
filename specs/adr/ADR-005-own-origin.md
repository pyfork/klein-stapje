# ADR-005: cvwriter is served from its own subdomain, not from a path on the shared site

<!-- prd-interviewer-Opus5.5-agent, 2026-10-19 -->

Status:   Accepted 2026-10-19. Amends the paths in ADR-003 and ADR-004.
Door:     one-way (the public address, cookies and every path depend on it)
Deciders: the owner

## Context
The first plan served cvwriter under a path (`/cvwriter/`) on a site that also serves other pages and small apps, some with their own write endpoints.

To a browser, every path on one host is the same origin. A script running on any of those other pages could call cvwriter's API with the signed-in user's cookie and read the replies, or load cvwriter in a frame and act inside it. Cookie paths, cvwriter's own CSP, and Referer or path checks don't prevent this.

The exposure is the user's ads, CVs and reference CVs, and Claude spend up to the user's stop. The Claude key itself never reaches the browser (ADR-001), and changing the password or key needs the current password (architecture, Sign-in).

The base path ends up in routes, asset URLs, cookies and redirects, so it is cheapest to settle before the walking skeleton.

## Options considered
1. **Keep the path on the shared site.**
   + Nothing to set up.
   − Every page on that host shares cvwriter's origin, and no in-origin control closes the gap.
2. **Its own subdomain of the same domain.**
   + A separate origin: other pages can't read its replies or reach into its frames. The app sits at `/`, so the cookie can use the `__Host-` prefix, which blocks cookies planted by sibling pages.
   − A DNS record, an nginx server block and a certificate. Sibling subdomains are still the same *site*, so requests sent from them carry the cookie; the `Origin` check and the JSON-only API refuse them.
3. **A separate domain.**
   + Fully separate site.
   − A domain to buy and renew, for no gain over option 2 here.

## Decision
- Option 2. cvwriter is served at the root of its own subdomain. The exact host name lives in configuration, not in the repository.
- **Paths** (amending ADR-003 and ADR-004): the SPA at `/`, the API under `/api/` (including `/api/telemetry` and `/api/cv-versions/{id}/download`), hashed assets under `/assets/`. The Cloudflare cache bypass applies to `/api/*`.
- **Cookie:** `__Host-session`, Path=/ (architecture, Sign-in).
- **Old address:** the old path on the shared site redirects to the subdomain, with or without a trailing slash, keeping the rest of the path: `302` while the subdomain is being set up, `301` once it is verified.
- **Proxying:** the subdomain's nginx server block sets `X-Real-IP` from the client address that the server already takes from Cloudflare, trusted only from Cloudflare's ranges.

## Consequences
+ No other page on the shared site can read cvwriter's data or act inside it.
+ The cookie can't be overwritten by a sibling path's cookie.
− One-time setup: a proxied DNS record, an nginx server block, a certificate, and the redirect on the shared site.
− Two addresses exist for a while. The redirect must stay until old links stop arriving.

## Revisit when
- Any other app is ever served under cvwriter's subdomain: it would share the origin again.
- The `301` redirect sees no traffic for 90 days: remove it.
