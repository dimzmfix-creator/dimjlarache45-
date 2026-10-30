// Perantara ke MangaDex untuk web Dimj Laraché (Vercel Function).
// Browser tidak boleh memanggil MangaDex langsung, jadi semua lewat sini.
const API = 'https://api.mangadex.org';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const HOST_OK = /^([a-z0-9-]+\.)*mangadex\.(org|network)$/i;
const LANGS = { id: 1, en: 1 };
const RATING = ['safe', 'suggestive'];
const MAX_IMG = 4400000; // Vercel membatasi respons maksimal 4,5 MB

const ua = (req) => 'DimjLarache-Reader/1.0 (+https://' + (req.headers.host || 'localhost') + ')';
const imgUrl = (u) => '/api/mangadex?a=img&u=' + encodeURIComponent(u);

function send(res, status, body, cache) {
  res.statusCode = status;
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (cache) res.setHeader('Cache-Control', cache);
  res.end(JSON.stringify(body));
}

async function md(req, path, params) {
  const u = new URL(API + path);
  for (const [k, v] of params) u.searchParams.append(k, v);
  const r = await fetch(u, { headers: { 'User-Agent': ua(req), Accept: 'application/json' } });
  if (r.status === 429) throw Object.assign(new Error('busy'), { code: 429 });
  if (!r.ok) throw Object.assign(new Error('upstream'), { code: 502 });
  return r.json();
}

function pick(obj, lang) {
  if (!obj || typeof obj !== 'object') return '';
  return obj[lang] || obj.en || Object.values(obj)[0] || '';
}

function ratings(p) { RATING.forEach((r) => p.push(['contentRating[]', r])); return p; }

async function report(u, ok, cached, bytes, t0) {
  // Aturan MangaDex: laporkan hasil memuat gambar dari server selain mangadex.org
  if (/mangadex\.org/i.test(u.hostname)) return;
  const send = fetch('https://api.mangadex.network/report', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ url: u.href, success: ok, cached, bytes, duration: Date.now() - t0 }),
  }).catch(() => {});
  await Promise.race([send, new Promise((r) => setTimeout(r, 1500))]);
}

module.exports = async (req, res) => {
  if (req.method !== 'GET') return send(res, 405, { error: 'Metode tidak didukung' });
  const q = req.query || Object.fromEntries(new URL(req.url, 'http://x').searchParams);
  const lang = LANGS[q.lang] ? q.lang : 'id';
  try {
    if (q.a === 'search') {
      const text = String(q.q || '').trim().slice(0, 100);
      const offset = Math.min(Math.max(parseInt(q.offset, 10) || 0, 0), 900);
      const p = [['limit', '20'], ['offset', String(offset)], ['includes[]', 'cover_art'], ['availableTranslatedLanguage[]', lang]];
      ratings(p);
      if (text) { p.push(['title', text]); p.push(['order[relevance]', 'desc']); }
      else p.push(['order[followedCount]', 'desc']);
      const j = await md(req, '/manga', p);
      const items = (j.data || []).map((m) => {
        const a = m.attributes || {};
        const c = (m.relationships || []).find((r) => r.type === 'cover_art');
        const fn = c && c.attributes && c.attributes.fileName;
        return {
          id: m.id,
          title: pick(a.title, lang),
          desc: String(pick(a.description, lang)).slice(0, 500),
          status: a.status || '',
          year: a.year || null,
          cover: fn ? imgUrl('https://uploads.mangadex.org/covers/' + m.id + '/' + fn + '.256.jpg') : '',
        };
      });
      return send(res, 200, { items, total: j.total || 0 }, 'public, s-maxage=300, stale-while-revalidate=600');
    }

    if (q.a === 'chapters') {
      if (!UUID.test(String(q.id))) return send(res, 400, { error: 'ID tidak valid' });
      const offset = Math.min(Math.max(parseInt(q.offset, 10) || 0, 0), 9900);
      const order = q.o === 'desc' ? 'desc' : 'asc';
      const p = [['limit', '100'], ['offset', String(offset)], ['translatedLanguage[]', lang], ['order[chapter]', order],
        ['includeExternalUrl', '0'], ['includeEmptyPages', '0'], ['includeFuturePublishAt', '0'], ['includes[]', 'scanlation_group']];
      ratings(p);
      const j = await md(req, '/manga/' + q.id + '/feed', p);
      const items = (j.data || []).filter((c) => c.attributes && c.attributes.pages > 0).map((c) => {
        const g = (c.relationships || []).find((r) => r.type === 'scanlation_group');
        return {
          id: c.id,
          ch: c.attributes.chapter || '',
          vol: c.attributes.volume || '',
          title: c.attributes.title || '',
          pages: c.attributes.pages,
          group: (g && g.attributes && g.attributes.name) || '',
        };
      });
      return send(res, 200, { items, total: j.total || 0 }, 'public, s-maxage=300, stale-while-revalidate=600');
    }

    if (q.a === 'pages') {
      if (!UUID.test(String(q.id))) return send(res, 400, { error: 'ID tidak valid' });
      const j = await md(req, '/at-home/server/' + q.id, []);
      const base = new URL(j.baseUrl);
      if (base.protocol !== 'https:' || !HOST_OK.test(base.hostname)) return send(res, 502, { error: 'Server gambar tidak valid' });
      const root = base.origin;
      const c = j.chapter || {};
      const pages = (c.data || []).map((f, i) => {
        const d = imgUrl(root + '/data/' + c.hash + '/' + f);
        const s = c.dataSaver && c.dataSaver[i] ? imgUrl(root + '/data-saver/' + c.hash + '/' + c.dataSaver[i]) : d;
        return { d, s };
      });
      return send(res, 200, { pages }, 'public, s-maxage=240');
    }

    if (q.a === 'img') {
      let u;
      try { u = new URL(String(q.u || '')); } catch (e) { return send(res, 400, { error: 'URL tidak valid' }); }
      if (u.protocol !== 'https:' || !HOST_OK.test(u.hostname) || !/^\/(covers|data|data-saver)\//.test(u.pathname)) {
        return send(res, 400, { error: 'URL tidak diizinkan' });
      }
      const t0 = Date.now();
      let buf = null, type = '', cached = false;
      try {
        const r = await fetch(u.href, { headers: { 'User-Agent': ua(req) }, redirect: 'error' });
        type = r.headers.get('content-type') || '';
        cached = (r.headers.get('x-cache') || '').toUpperCase().startsWith('HIT');
        if (r.ok && type.startsWith('image/')) buf = Buffer.from(await r.arrayBuffer());
      } catch (e) { buf = null; }
      await report(u, !!buf, cached, buf ? buf.length : 0, t0);
      if (!buf) return send(res, 502, { error: 'Gagal memuat gambar' });
      if (buf.length > MAX_IMG) return send(res, 413, { error: 'Gambar terlalu besar' });
      res.statusCode = 200;
      res.setHeader('Content-Type', type);
      res.setHeader('Cache-Control', 'public, max-age=86400, s-maxage=31536000, immutable');
      return res.end(buf);
    }

    return send(res, 400, { error: 'Aksi tidak valid' });
  } catch (e) {
    return send(res, e.code === 429 ? 429 : 502,
      { error: e.code === 429 ? 'Server sedang ramai, coba lagi sebentar.' : 'Gagal menghubungi sumber komik.' });
  }
};
