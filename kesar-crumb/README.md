# Kesar & Crumb — self-hosted bakery shop + CRM

A single-server bakery storefront with ordering, order tracking, loyalty points,
promo codes, guest feedback, WhatsApp handoff, and a PIN-locked admin desk
(dashboard, orders, delivery run, guests/CRM, stock & menu, promos, settings).

- **Backend**: Node 18+ / Express, one dependency. State lives in `data/data.json`
  (atomic writes, created on first run). Prices, stock, promo and loyalty math are
  all validated server-side; the admin PIN never leaves the server.
- **Frontend**: a single static page (`public/index.html`), hash-routed
  (`/#checkout`, `/#track`, `/#feedback`, `/#admin`), no build step.

## Run it

```bash
npm install
node server.js            # http://localhost:3000
```

Environment variables (all optional):

| Var | Default | Meaning |
|---|---|---|
| `PORT` | `3000` | HTTP port |
| `DATA_DIR` | `./data` | where `data.json` lives |
| `ADMIN_PIN` | `2016` | initial desk PIN (changeable in Settings; only used on first run) |
| `SHOP_WHATSAPP` | `919810000000` | initial shop WhatsApp number (changeable in Settings) |

## Deploy on a VPS (Ubuntu/Debian)

```bash
# 1. Node 20
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs

# 2. App
sudo mkdir -p /opt/kesar-crumb && sudo chown $USER /opt/kesar-crumb
# copy this folder there (git clone, scp, rsync — whatever you use), then:
cd /opt/kesar-crumb
npm install --omit=dev
ADMIN_PIN=YOUR_PIN node server.js   # test run, Ctrl-C when happy
```

### Keep it running (systemd)

`/etc/systemd/system/kesar-crumb.service`:

```ini
[Unit]
Description=Kesar & Crumb bakery shop
After=network.target

[Service]
WorkingDirectory=/opt/kesar-crumb
ExecStart=/usr/bin/node server.js
Restart=always
Environment=PORT=3000
Environment=ADMIN_PIN=change-me-please
User=www-data

[Install]
WantedBy=multi-user.target
```

```bash
sudo chown -R www-data:www-data /opt/kesar-crumb/data
sudo systemctl daemon-reload
sudo systemctl enable --now kesar-crumb
```

### Put it behind nginx + HTTPS

Geolocation ("pin my current location" at checkout) only works over **HTTPS**,
so a certificate isn't optional if you want that feature.

```nginx
server {
    server_name bakery.example.com;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

```bash
sudo apt-get install -y nginx certbot python3-certbot-nginx
sudo certbot --nginx -d bakery.example.com
```

### Or Docker

```bash
docker build -t kesar-crumb .
docker run -d --name kesar-crumb -p 3000:3000 \
  -e ADMIN_PIN=change-me-please \
  -v kesar-data:/app/data \
  kesar-crumb
```

## First steps after deploy

1. Open `/#admin`, log in with your PIN, and change it in **Settings** if you
   set it via env on an existing data file (env values only seed the first run).
2. Set the real shop WhatsApp number in **Settings** — guests' "Send on
   WhatsApp" after checkout goes there.
3. Set the morning's tray counts in **Stock & menu**.
4. Promo codes `KESAR10` and `CRUMB50` are pre-seeded — edit them in **Promos**.

## API sketch

Public: `GET /api/boot`, `POST /api/orders`, `GET /api/track?q=`,
`POST /api/feedback`, `GET /api/promo/:code`, `GET /api/loyalty?phone=`.

Admin (Bearer token from `POST /api/admin/login {pin}`): `GET /api/admin/state`,
`POST /api/admin/orders/:id/status`, `PUT /api/admin/menu`,
`POST|PATCH|DELETE /api/admin/promos[/:code]`, `PUT /api/admin/customers/:key`,
`PATCH|DELETE /api/admin/feedback/:id`, `PUT /api/admin/settings`,
`POST /api/admin/wipe`, `GET /api/admin/export/orders.csv|guests.csv`.

## Notes

- Admin sessions are in-memory tokens (12 h, sliding); a server restart logs
  the desk out. Login is lightly rate-limited.
- The JSON-file store is comfortable for a single shop's volume. If you outgrow
  it, the storage layer is ~30 lines in `server.js` — swap in SQLite/Postgres there.
- This started life as a demo for a fictional patisserie; all brand names,
  ateliers and phone numbers are placeholders. Swap the copy in
  `public/index.html` before pointing customers at it.
