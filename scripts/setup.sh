#!/bin/bash
# Cumulus://ID Russia on Yandex (cumulus-id-russia, Ubuntu 24.04).
# A separate issuer for Russian accounts: https://ru-id.cumuluscloud.app. Its accounts, passkeys and
# sessions live only on this server. No Claude, no social sign-in, no outside mail or SMS providers.
# Re-runnable; run again to upgrade (bump SHA).
set -euo pipefail
# infinitum-nexus commit to run (apps/spectre, the code behind id.cumuluscloud.app).
SHA=${NEXUS_SHA:-990139e70fc4556b6377da68f5993b37a2868dec}
HOST=ru-id.cumuluscloud.app
MYIP=${MYIP:-46.21.246.216}
NODE_VERSION=v24.11.0
PNPM_VERSION=10.28.0
PORT=3000
log() { echo "[cumulus-id] $*"; }
TMP=$(mktemp -d)

sudo DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get -qq install -y nginx certbot xz-utils >/dev/null

# Node (official build, checksum-verified)
if [ "$(/usr/local/bin/node -v 2>/dev/null || true)" != "$NODE_VERSION" ]; then
  f="node-$NODE_VERSION-linux-x64.tar.xz"
  curl -fsSL -o "$TMP/$f" "https://nodejs.org/dist/$NODE_VERSION/$f"
  curl -fsSL -o "$TMP/SHASUMS256.txt" "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt"
  (cd "$TMP" && grep " $f\$" SHASUMS256.txt | sha256sum -c - >/dev/null)
  sudo tar -xJf "$TMP/$f" -C /usr/local --strip-components=1 --no-same-owner
fi
log "node $(/usr/local/bin/node -v)"

id cumulusid >/dev/null 2>&1 || sudo useradd --system --home-dir /var/lib/cumulus-id --shell /usr/sbin/nologin cumulusid
sudo install -d -o cumulusid -g cumulusid -m 0700 /var/lib/cumulus-id
sudo install -d -m 0755 /opt/cumulus-id/releases /var/www/acme
sudo install -d -m 0700 /etc/cumulus-id

# Code: InfinitumCorp/infinitum-nexus at a pinned commit, only what apps/spectre needs
REL=/opt/cumulus-id/releases/$SHA
if ! sudo test -f "$REL/apps/spectre/src/server/main.ts"; then
  sudo rm -rf "$REL"; sudo mkdir -p "$REL"
  curl -fsSL "https://codeload.github.com/InfinitumCorp/infinitum-nexus/tar.gz/$SHA" | sudo tar -xz --strip-components=1 -C "$REL" --no-same-owner
  (cd "$REL" && sudo env PATH=/usr/local/bin:$PATH COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
    npx -y "pnpm@$PNPM_VERSION" install --filter "@infinitum/spectre..." --frozen-lockfile --reporter=silent)
  sudo chown -R root:root "$REL"; sudo chmod -R a+rX "$REL"
fi
sudo ln -sfn "$REL" /opt/cumulus-id/current
log "code $SHA"

# OpenID Connect signing key: generated here once, root-only, never printed or copied off the server.
if ! sudo test -f /etc/cumulus-id/oidc-signing-key.jwk; then
  sudo /usr/local/bin/node "$REL/apps/spectre/scripts/generate-oidc-key.mjs" /etc/cumulus-id/oidc-signing-key.jwk | grep -v '^  npx' || true
fi
sudo chmod 600 /etc/cumulus-id/oidc-signing-key.jwk

# Settings (no secrets here). The cookie stays on this host so it never mixes with id.cumuluscloud.app.
sudo tee /etc/cumulus-id/env >/dev/null <<EOF
# Cumulus://ID Russia. No social sign-in, mail or SMS providers: nothing leaves Russia.
NODE_ENV=production
PORT=$PORT
SPECTRE_ORIGIN=https://$HOST
CUMULUS_ID_HOST=$HOST
CUMULUS_COOKIE_DOMAIN=$HOST
SPECTRE_DATA_DIR=/var/lib/cumulus-id
USE_METATRON=1
EOF
sudo chmod 600 /etc/cumulus-id/env

# Guards: no Claude, and no keys for services outside Russia.
for bad in ANTHROPIC_API_KEY OMNIROUTE_API_KEY RESEND_API_KEY TWILIO_AUTH_TOKEN GOOGLE_CLIENT_SECRET GITHUB_CLIENT_SECRET MICROSOFT_CLIENT_SECRET COGNITO_CLIENT_SECRET; do
  if sudo grep -q "^$bad=" /etc/cumulus-id/env; then
    echo "[cumulus-id] $bad must not be set on the Russia server" >&2; exit 1
  fi
done

# The key is one line of JSON. At each start root copies it to /run (readable only by the service user)
# and the service reads it into its own environment, so it never sits in a unit file or the env file.
sudo tee /etc/systemd/system/cumulus-id.service >/dev/null <<EOF
[Unit]
Description=Cumulus://ID (Russia)
After=network-online.target
Wants=network-online.target

[Service]
User=cumulusid
Group=cumulusid
WorkingDirectory=/opt/cumulus-id/current/apps/spectre
EnvironmentFile=/etc/cumulus-id/env
ExecStartPre=+/bin/sh -c 'install -m 0400 -o cumulusid -g cumulusid /etc/cumulus-id/oidc-signing-key.jwk /run/cumulus-id-key.jwk'
ExecStart=/bin/sh -c 'CID_OIDC_SIGNING_KEY=\$(cat /run/cumulus-id-key.jwk) exec /usr/local/bin/node src/server/main.ts'
Restart=always
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/cumulus-id
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable cumulus-id >/dev/null 2>&1
sudo systemctl restart cumulus-id
for _ in $(seq 1 60); do curl -fsS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null && break; sleep 1; done
log "local /: $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
log "local discovery: $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/.well-known/openid-configuration")"

# HTTP: ACME challenges only, everything else to HTTPS
sudo tee /etc/nginx/sites-available/default >/dev/null <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    server_tokens off;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
sudo nginx -t -q && sudo systemctl reload nginx

resolves() {
  for _ in 1 2 3 4 5; do
    [ "$(getent ahostsv4 "$1" | awk '{print $1; exit}')" = "$MYIP" ] && return 0
    sleep 3
  done
  return 1
}
if ! resolves $HOST; then
  log "DNS for $HOST does not point at $MYIP yet; HTTPS skipped"
  exit 0
fi
if ! sudo test -f /etc/letsencrypt/live/$HOST/fullchain.pem; then
  sudo certbot certonly --webroot -w /var/www/acme -d $HOST --non-interactive --agree-tos --register-unsafely-without-email --quiet
fi
sudo tee /etc/nginx/sites-available/cumulus-id-russia >/dev/null <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $HOST;
    server_tokens off;
    ssl_certificate     /etc/letsencrypt/live/$HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Strict-Transport-Security "max-age=31536000" always;
    client_max_body_size 20M;
    gzip on;
    location / {
        proxy_pass http://127.0.0.1:$PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 300s;
    }
}
EOF
sudo ln -sf /etc/nginx/sites-available/cumulus-id-russia /etc/nginx/sites-enabled/cumulus-id-russia
sudo nginx -t -q && sudo systemctl reload nginx
echo -e '#!/bin/sh\nsystemctl reload nginx' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh >/dev/null
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
log "cert: $(sudo openssl x509 -in /etc/letsencrypt/live/$HOST/fullchain.pem -noout -enddate)"
