#!/usr/bin/env bash
# Kesar & Crumb — one-shot VPS deploy (Ubuntu/Debian, run as root)
#
#   bash deploy.sh                 # serve on http://<server-ip>/
#   bash deploy.sh bakery.example.com   # + nginx server_name & Let's Encrypt HTTPS
#
# Idempotent: safe to re-run for updates. Order data in /opt/kesar-crumb/data
# survives redeploys.
set -euo pipefail

REPO="https://github.com/A-tndn/VisionClaw"
BRANCH="claude/theobroma-site-review-77s37x"
APP_DIR="/opt/kesar-crumb"
DOMAIN="${1:-}"

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash deploy.sh)"; exit 1; }

echo "==> Packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl git nginx

echo "==> Node.js 20"
if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'parseInt(process.versions.node)')" -lt 18 ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
fi
node -v

echo "==> Fetch app ($BRANCH)"
rm -rf /tmp/kc-src
git clone --depth 1 -b "$BRANCH" "$REPO" /tmp/kc-src
mkdir -p "$APP_DIR"
cp -r /tmp/kc-src/kesar-crumb/. "$APP_DIR/"
rm -rf /tmp/kc-src
cd "$APP_DIR"
npm install --omit=dev --no-fund --no-audit

FIRST_RUN=0
if [ ! -f "$APP_DIR/data/data.json" ]; then
  FIRST_RUN=1
  ADMIN_PIN="$(shuf -i 100000-999999 -n 1)"
else
  ADMIN_PIN=""
fi

echo "==> systemd service"
id -u kesar >/dev/null 2>&1 || useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin kesar
mkdir -p "$APP_DIR/data"
chown -R kesar:kesar "$APP_DIR"
cat > /etc/systemd/system/kesar-crumb.service <<EOF
[Unit]
Description=Kesar & Crumb bakery shop
After=network.target

[Service]
WorkingDirectory=$APP_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=3
User=kesar
Environment=PORT=3000
${ADMIN_PIN:+Environment=ADMIN_PIN=$ADMIN_PIN}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kesar-crumb >/dev/null 2>&1 || true
systemctl restart kesar-crumb

echo "==> nginx"
SERVER_NAME="${DOMAIN:-_}"
cat > /etc/nginx/sites-available/kesar-crumb <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $SERVER_NAME;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
ln -sf /etc/nginx/sites-available/kesar-crumb /etc/nginx/sites-enabled/kesar-crumb
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl reload nginx

if [ -n "$DOMAIN" ]; then
  echo "==> HTTPS via Let's Encrypt for $DOMAIN"
  apt-get install -y certbot python3-certbot-nginx
  certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect || {
    echo "certbot failed — check that the domain's DNS A record points at this server, then re-run:"
    echo "  certbot --nginx -d $DOMAIN"
  }
fi

sleep 1
systemctl --no-pager --lines=0 status kesar-crumb || true
IP="$(curl -s -4 --max-time 5 ifconfig.me || hostname -I | awk '{print $1}')"
echo
echo "======================================================================"
echo " Kesar & Crumb is live."
if [ -n "$DOMAIN" ]; then
  echo "   Shop:         https://$DOMAIN/"
  echo "   Atelier desk: https://$DOMAIN/#admin"
else
  echo "   Shop:         http://$IP/"
  echo "   Atelier desk: http://$IP/#admin"
  echo "   Note: without a domain there is no HTTPS, and the checkout's"
  echo "   'pin my location' button needs HTTPS to work. Re-run with:"
  echo "     bash deploy.sh your-domain.com"
fi
if [ "$FIRST_RUN" -eq 1 ]; then
  echo "   Desk PIN:     $ADMIN_PIN   (change it in Settings after first login)"
else
  echo "   Desk PIN:     unchanged (existing data kept)"
fi
echo "   Data file:    $APP_DIR/data/data.json"
echo "   Logs:         journalctl -u kesar-crumb -f"
echo "======================================================================"
