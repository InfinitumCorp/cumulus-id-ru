# Cumulus://ID Russia

Cumulus://ID for Russian accounts, at **https://ru-id.cumuluscloud.app**, on the Yandex Cloud server `cumulus-id-russia` (ru-central1-a).

- A separate issuer: Russian accounts, passkeys and sessions are stored only on this server. Its sessions are scoped to `ru-id.cumuluscloud.app`, so they never mix with `id.cumuluscloud.app`.
- Runs `apps/spectre` from [InfinitumCorp/infinitum-nexus](https://github.com/InfinitumCorp/infinitum-nexus) at a pinned commit (`SHA` in `scripts/setup.sh`), on Node, behind nginx with Let's Encrypt.
- Nothing leaves Russia: no Claude, no social sign-in, no outside mail or SMS providers. `setup.sh` refuses to run if any of their keys are set.
- The OpenID Connect signing key is generated on the server (`/etc/cumulus-id/oidc-signing-key.jwk`, root-only). It is never printed, copied or committed.
- Data: `/var/lib/cumulus-id`, covered by the daily Yandex disk snapshots (`daily-data-servers`, 7 kept).

Not to be confused with `ru.id.cumuluscloud.app`, which is a mirror that forwards to the US issuer.

## Scripts

- `scripts/setup.sh`: run on the server (`ssh cumulus-id-russia 'bash -s' < scripts/setup.sh`). Safe to re-run; bump `SHA` to upgrade.
- `scripts/check.sh`: checks the live site (home, OIDC discovery, issuer, HTTPS redirect, cookie scope).

## Status

- 2026-11-12: running on the server (systemd `cumulus-id`, port 3000 behind nginx). Issuer `https://ru-id.cumuluscloud.app/realms/cumulus`, signing key id `Vkewk4VI1-4iJnYD`. Sign-in: passkeys. AI: not connected.
- 2026-11-12: live at https://ru-id.cumuluscloud.app. DNS `A ru-id.cumuluscloud.app → 46.21.246.216` (DNS only, Cloudflare). Let's Encrypt certificate valid to 2027-02-10. `check.sh` passes from GitHub's network.
- The public IP is dynamic: make it static before launch, or the DNS record breaks if the server is stopped.

## Still to do

- Apps must accept this issuer for Russian accounts (sign-in routing by account residency), in infinitum-nexus and each app.
- Each app that signs in here must be registered as a client on this issuer.
