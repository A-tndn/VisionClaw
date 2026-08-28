/* Kesar & Crumb — self-hosted bakery shop + CRM
 * Node 18+, single dependency (express). State lives in data/data.json.
 */
'use strict';

const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const PORT = process.env.PORT || 3000;
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
const DATA_FILE = path.join(DATA_DIR, 'data.json');

/* ---------- catalogue (server is the source of truth for prices) ---------- */
const PRODUCTS = [
  { id: 'saffron-croissant', name: 'Saffron Pistachio Croissant', price: 280 },
  { id: 'cardamom-kouign',   name: 'Cardamom Kouign-Amann',       price: 320 },
  { id: 'rose-entremet',     name: 'Rose & Raspberry Entremet',   price: 650 },
  { id: 'gondhoraj-tart',    name: 'Gondhoraj Lemon Tart',        price: 420 },
  { id: 'cacao-torte',       name: '72% Single-Origin Torte',     price: 580 },
  { id: 'filter-tiramisu',   name: 'Filter Coffee Tiramisu',      price: 520 },
  { id: 'jaggery-brownie',   name: 'Jaggery Walnut Brownie',      price: 240 },
  { id: 'mawa-bun',          name: 'Mawa Bun, Smoked Butter',     price: 190 }
];
const byId = Object.fromEntries(PRODUCTS.map(p => [p.id, p]));

/* ---------- storage ---------- */
const DEFAULT_STATE = {
  orders: [],
  feedback: [],
  customers: {},
  menu: {},
  promos: [
    { code: 'KESAR10', type: 'percent', value: 10, active: true },
    { code: 'CRUMB50', type: 'flat', value: 50, active: true }
  ],
  settings: { pin: process.env.ADMIN_PIN || '2016', whatsapp: process.env.SHOP_WHATSAPP || '919810000000' }
};

let state;
function load() {
  try {
    state = JSON.parse(fs.readFileSync(DATA_FILE, 'utf8'));
  } catch (e) {
    state = null;
  }
  if (!state || typeof state !== 'object') state = JSON.parse(JSON.stringify(DEFAULT_STATE));
  for (const k of ['orders', 'feedback']) if (!Array.isArray(state[k])) state[k] = [];
  if (!Array.isArray(state.promos)) state.promos = DEFAULT_STATE.promos;
  for (const k of ['customers', 'menu', 'settings']) if (!state[k] || typeof state[k] !== 'object') state[k] = {};
  if (!state.settings.pin) state.settings.pin = DEFAULT_STATE.settings.pin;
  if (!state.settings.whatsapp) state.settings.whatsapp = DEFAULT_STATE.settings.whatsapp;
}
function save() {
  fs.mkdirSync(DATA_DIR, { recursive: true });
  const tmp = DATA_FILE + '.tmp';
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2));
  fs.renameSync(tmp, DATA_FILE);
}
load();
save();

/* ---------- helpers ---------- */
const phoneKey = p => String(p || '').replace(/\D/g, '').slice(-10);
const effPrice = id => (state.menu[id] && state.menu[id].price > 0) ? state.menu[id].price : byId[id].price;
const stockOf = id => (state.menu[id] && typeof state.menu[id].stock === 'number') ? state.menu[id].stock : null;
const isSold = id => {
  const o = state.menu[id];
  if (o && o.soldOut) return true;
  const s = stockOf(id);
  return s !== null && s <= 0;
};
function loyaltyBalance(phone) {
  const k = phoneKey(phone);
  if (!k || k.length < 8) return 0;
  let b = 0;
  for (const o of state.orders) {
    if (o.status === 'cancelled' || phoneKey(o.phone) !== k) continue;
    b += (o.pointsEarned || 0) - (o.pointsRedeemed || 0);
  }
  return Math.max(0, b);
}
function publicMenu() {
  return PRODUCTS.map(p => ({
    id: p.id, name: p.name, list: p.price,
    price: effPrice(p.id), stock: stockOf(p.id), sold: isSold(p.id)
  }));
}
function guestbook() {
  return state.feedback
    .filter(f => !f.hidden && f.rating >= 4)
    .slice(-3).reverse()
    .map(f => ({ name: f.name, rating: f.rating, comment: f.comment, reply: f.reply || '' }));
}
function adminState() {
  return {
    orders: state.orders, feedback: state.feedback, customers: state.customers,
    menu: state.menu, promos: state.promos,
    settings: { whatsapp: state.settings.whatsapp } // never ship the PIN
  };
}
const clean = (v, max) => String(v == null ? '' : v).slice(0, max || 300).trim();

/* ---------- admin tokens ---------- */
const tokens = new Map(); // token -> expiry ms
const TOKEN_TTL = 12 * 3600 * 1000;
let loginFails = 0, loginLockUntil = 0;
function requireAdmin(req, res, next) {
  const h = String(req.headers.authorization || '');
  const t = h.startsWith('Bearer ') ? h.slice(7) : '';
  const exp = tokens.get(t);
  if (!exp || exp < Date.now()) return res.status(401).json({ error: 'unauthorized' });
  tokens.set(t, Date.now() + TOKEN_TTL);
  next();
}

/* ---------- app ---------- */
const app = express();
app.disable('x-powered-by');
app.use(express.json({ limit: '64kb' }));
app.use(express.static(path.join(__dirname, 'public')));

/* ----- public API ----- */
app.get('/api/boot', (req, res) => {
  res.json({ menu: publicMenu(), guestbook: guestbook(), whatsapp: state.settings.whatsapp });
});

app.get('/api/promo/:code', (req, res) => {
  const code = clean(req.params.code, 24).toUpperCase();
  const hit = state.promos.find(p => p.active && String(p.code).toUpperCase() === code);
  if (!hit) return res.status(404).json({ error: 'unknown_code' });
  res.json({ code: hit.code, type: hit.type, value: hit.value });
});

app.get('/api/loyalty', (req, res) => {
  res.json({ points: loyaltyBalance(clean(req.query.phone, 24)) });
});

app.post('/api/orders', (req, res) => {
  const b = req.body || {};
  const items = b.items && typeof b.items === 'object' ? b.items : {};
  const lines = [];
  for (const id of Object.keys(items)) {
    const qty = Math.floor(Number(items[id]));
    if (!byId[id] || !(qty >= 1 && qty <= 20)) continue;
    lines.push({ id, qty });
  }
  if (!lines.length) return res.status(400).json({ error: 'empty', message: 'The box is empty.' });

  const name = clean(b.name, 80), phone = clean(b.phone, 24);
  const mode = b.mode === 'delivery' ? 'delivery' : 'pickup';
  const address = clean(b.address, 500), note = clean(b.note, 500);
  const date = clean(b.date, 10), atelier = clean(b.atelier, 60);
  if (!name) return res.status(400).json({ error: 'name', message: 'A name, so we can call the order.' });
  if (!/^[\d+\s-]{8,}$/.test(phone)) return res.status(400).json({ error: 'phone', message: 'A phone number we can actually reach.' });
  if (mode === 'delivery' && !address) return res.status(400).json({ error: 'address', message: 'Delivery needs an address or a pinned location.' });

  const short = [];
  for (const l of lines) {
    if (isSold(l.id)) short.push(byId[l.id].name + ' (sold out)');
    else { const s = stockOf(l.id); if (s !== null && s < l.qty) short.push(byId[l.id].name + ' (only ' + s + ' left)'); }
  }
  if (short.length) return res.status(409).json({ error: 'stock', message: 'The tray emptied while you shopped: ' + short.join(', ') + '.' });

  const subtotal = lines.reduce((s, l) => s + effPrice(l.id) * l.qty, 0);
  let promo = null, promoOff = 0;
  if (b.promoCode) {
    const code = clean(b.promoCode, 24).toUpperCase();
    const hit = state.promos.find(p => p.active && String(p.code).toUpperCase() === code);
    if (!hit) return res.status(400).json({ error: 'promo', message: 'That code isn’t on the list.' });
    promoOff = hit.type === 'percent' ? Math.round(subtotal * hit.value / 100) : Math.min(hit.value, subtotal);
    promo = { code: hit.code, off: promoOff };
  }
  const maxPts = Math.min(loyaltyBalance(phone), Math.floor((subtotal - promoOff) / 2));
  const pts = Math.min(Math.max(0, Math.floor(Number(b.usePoints) || 0)), maxPts);
  const total = Math.max(0, subtotal - promoOff - pts);

  const order = {
    id: 'KC-' + Date.now().toString(36).toUpperCase().slice(-6) + crypto.randomBytes(1).toString('hex').toUpperCase(),
    ts: new Date().toISOString(),
    name, phone, mode, address: mode === 'delivery' ? address : '',
    date, atelier, note, status: 'new',
    items: lines.map(l => ({ id: l.id, name: byId[l.id].name, qty: l.qty, price: effPrice(l.id) })),
    subtotal, promo, pointsRedeemed: pts, pointsEarned: Math.round(total * 0.05), total
  };
  for (const l of lines) {
    if (state.menu[l.id] && typeof state.menu[l.id].stock === 'number') {
      state.menu[l.id].stock = Math.max(0, state.menu[l.id].stock - l.qty);
    }
  }
  state.orders.push(order);
  state.orders = state.orders.slice(-2000);
  save();
  res.json({ order, menu: publicMenu() });
});

app.get('/api/track', (req, res) => {
  const q = clean(req.query.q, 40);
  if (!q) return res.json({ orders: [] });
  const pk = phoneKey(q), qq = q.toUpperCase();
  const hits = state.orders
    .filter(o => o.id.toUpperCase() === qq || (pk.length >= 8 && phoneKey(o.phone) === pk))
    .slice(-4).reverse()
    .map(o => ({ id: o.id, status: o.status, mode: o.mode, date: o.date, total: o.total, items: o.items }));
  res.json({ orders: hits });
});

app.post('/api/feedback', (req, res) => {
  const b = req.body || {};
  const rating = Math.min(5, Math.max(1, Math.floor(Number(b.rating) || 5)));
  const comment = clean(b.comment, 600);
  if (!comment) return res.status(400).json({ error: 'comment', message: 'A word or two — the bakers read everything.' });
  state.feedback.push({
    id: 'FB-' + Date.now().toString(36).toUpperCase().slice(-6),
    ts: new Date().toISOString(),
    name: clean(b.name, 80), orderId: clean(b.orderId, 20), rating, comment
  });
  state.feedback = state.feedback.slice(-1000);
  save();
  res.json({ ok: true });
});

/* ----- admin API ----- */
app.post('/api/admin/login', (req, res) => {
  if (Date.now() < loginLockUntil) return res.status(429).json({ error: 'locked', message: 'Too many tries — wait a minute.' });
  const pin = clean((req.body || {}).pin, 12);
  if (pin !== String(state.settings.pin)) {
    loginFails++;
    if (loginFails >= 8) { loginLockUntil = Date.now() + 60000; loginFails = 0; }
    return res.status(401).json({ error: 'pin', message: 'That’s not it.' });
  }
  loginFails = 0;
  const t = crypto.randomBytes(24).toString('hex');
  tokens.set(t, Date.now() + TOKEN_TTL);
  res.json({ token: t });
});

app.get('/api/admin/state', requireAdmin, (req, res) => res.json(adminState()));

app.post('/api/admin/orders/:id/status', requireAdmin, (req, res) => {
  const st = clean((req.body || {}).status, 12);
  if (!['new', 'confirmed', 'baking', 'ready', 'out', 'completed', 'cancelled'].includes(st)) {
    return res.status(400).json({ error: 'status' });
  }
  const o = state.orders.find(x => x.id === req.params.id);
  if (!o) return res.status(404).json({ error: 'not_found' });
  o.status = st;
  save();
  res.json(adminState());
});

app.put('/api/admin/menu', requireAdmin, (req, res) => {
  const inMenu = (req.body || {}).menu || {};
  const menu = {};
  for (const p of PRODUCTS) {
    const e = inMenu[p.id];
    if (!e || typeof e !== 'object') continue;
    const entry = {};
    const price = Math.floor(Number(e.price));
    if (price > 0 && price !== p.price) entry.price = price;
    if (e.stock !== null && e.stock !== undefined && e.stock !== '') {
      const s = Math.floor(Number(e.stock));
      if (s >= 0) entry.stock = s;
    }
    if (e.soldOut) entry.soldOut = true;
    if (Object.keys(entry).length) menu[p.id] = entry;
  }
  state.menu = menu;
  save();
  res.json(adminState());
});

app.post('/api/admin/promos', requireAdmin, (req, res) => {
  const b = req.body || {};
  const code = clean(b.code, 16).toUpperCase();
  const type = b.type === 'flat' ? 'flat' : 'percent';
  const value = Math.floor(Number(b.value));
  if (!/^[A-Z0-9]{3,16}$/.test(code)) return res.status(400).json({ error: 'code', message: 'Code: 3–16 letters or digits.' });
  if (!(value > 0) || (type === 'percent' && value > 90)) return res.status(400).json({ error: 'value', message: type === 'percent' ? 'Percent: 1–90.' : 'Amount must be above zero.' });
  if (state.promos.some(p => String(p.code).toUpperCase() === code)) return res.status(409).json({ error: 'dup', message: 'That code already exists.' });
  state.promos.push({ code, type, value, active: true });
  save();
  res.json(adminState());
});
app.patch('/api/admin/promos/:code', requireAdmin, (req, res) => {
  const p = state.promos.find(x => String(x.code).toUpperCase() === req.params.code.toUpperCase());
  if (!p) return res.status(404).json({ error: 'not_found' });
  p.active = !!(req.body || {}).active;
  save();
  res.json(adminState());
});
app.delete('/api/admin/promos/:code', requireAdmin, (req, res) => {
  state.promos = state.promos.filter(x => String(x.code).toUpperCase() !== req.params.code.toUpperCase());
  save();
  res.json(adminState());
});

app.put('/api/admin/customers/:key', requireAdmin, (req, res) => {
  const key = phoneKey(req.params.key);
  if (!key) return res.status(400).json({ error: 'key' });
  const b = req.body || {};
  const cur = state.customers[key] || {};
  if ('note' in b) cur.note = clean(b.note, 500);
  if ('tag' in b) cur.tag = clean(b.tag, 20);
  state.customers[key] = cur;
  save();
  res.json(adminState());
});

app.patch('/api/admin/feedback/:id', requireAdmin, (req, res) => {
  const f = state.feedback.find(x => x.id === req.params.id);
  if (!f) return res.status(404).json({ error: 'not_found' });
  const b = req.body || {};
  if ('reply' in b) f.reply = clean(b.reply, 500);
  if ('hidden' in b) f.hidden = !!b.hidden;
  save();
  res.json(adminState());
});
app.delete('/api/admin/feedback/:id', requireAdmin, (req, res) => {
  state.feedback = state.feedback.filter(x => x.id !== req.params.id);
  save();
  res.json(adminState());
});

app.put('/api/admin/settings', requireAdmin, (req, res) => {
  const b = req.body || {};
  if (b.pin !== undefined) {
    const pin = clean(b.pin, 8);
    if (!/^\d{4,8}$/.test(pin)) return res.status(400).json({ error: 'pin', message: 'PIN must be 4–8 digits.' });
    state.settings.pin = pin;
  }
  if (b.whatsapp !== undefined) {
    const wa = clean(b.whatsapp, 20);
    if (wa.replace(/\D/g, '').length < 10) return res.status(400).json({ error: 'whatsapp', message: 'That doesn’t look like a full number.' });
    state.settings.whatsapp = wa;
  }
  save();
  res.json(adminState());
});

app.post('/api/admin/wipe', requireAdmin, (req, res) => {
  state.orders = []; state.feedback = []; state.customers = {};
  save();
  res.json(adminState());
});

function csvCell(v) { return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"'; }
app.get('/api/admin/export/:kind', requireAdmin, (req, res) => {
  let rows, name;
  if (req.params.kind === 'orders.csv') {
    name = 'kesar-crumb-orders.csv';
    rows = [['id', 'placed', 'name', 'phone', 'mode', 'atelier', 'for_date', 'status', 'subtotal_inr', 'promo', 'promo_off_inr', 'points_redeemed', 'points_earned', 'total_inr', 'items', 'note']]
      .concat(state.orders.map(o => [o.id, o.ts, o.name, o.phone, o.mode, o.atelier, o.date, o.status, o.subtotal || o.total,
        (o.promo && o.promo.code) || '', (o.promo && o.promo.off) || 0, o.pointsRedeemed || 0, o.pointsEarned || 0, o.total,
        (o.items || []).map(it => it.qty + 'x ' + it.name).join('; '), o.note]));
  } else if (req.params.kind === 'guests.csv') {
    name = 'kesar-crumb-guests.csv';
    const m = {};
    for (const o of state.orders) {
      if (o.status === 'cancelled') continue;
      const k = phoneKey(o.phone); if (!k) continue;
      if (!m[k]) m[k] = { name: o.name, phone: o.phone, count: 0, spend: 0, last: o.ts, key: k };
      m[k].count++; m[k].spend += o.total || 0;
      if (o.ts > m[k].last) { m[k].last = o.ts; m[k].name = o.name; m[k].phone = o.phone; }
    }
    rows = [['name', 'phone', 'orders', 'spend_inr', 'last_order', 'points', 'note']]
      .concat(Object.values(m).map(c => [c.name, c.phone, c.count, c.spend, c.last, loyaltyBalance(c.phone), (state.customers[c.key] || {}).note || '']));
  } else {
    return res.status(404).json({ error: 'not_found' });
  }
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', 'attachment; filename="' + name + '"');
  res.send(rows.map(r => r.map(csvCell).join(',')).join('\r\n'));
});

/* SPA-ish fallback: unknown non-API paths get the page */
app.get(/^\/(?!api\/).*/, (req, res) => res.sendFile(path.join(__dirname, 'public', 'index.html')));

app.listen(PORT, () => console.log('Kesar & Crumb listening on http://0.0.0.0:' + PORT));
