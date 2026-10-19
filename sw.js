// Horus Hotel : installation et ouverture hors connexion de l'interface (les données restent en ligne)
const C = 'horus-v2';
self.addEventListener('install', e => { self.skipWaiting(); e.waitUntil(caches.open(C).then(c => c.addAll(['./', './manifest.webmanifest', './icon-192.png', './icon-512.png']))); });
self.addEventListener('activate', e => e.waitUntil(caches.keys().then(k => Promise.all(k.filter(x => x !== C).map(x => caches.delete(x)))).then(() => self.clients.claim())));
self.addEventListener('fetch', e => {
  const u = new URL(e.request.url);
  if (e.request.method !== 'GET' || u.origin !== location.origin) return;
  const fresh = e.request.mode === 'navigate' || u.pathname.endsWith('/') || u.pathname.endsWith('.html') || u.pathname.endsWith('sw.js');
  e.respondWith(fetch(e.request, fresh ? { cache: 'no-cache' } : undefined).then(r => { const c = r.clone(); caches.open(C).then(x => x.put(e.request, c)); return r; }).catch(() => caches.match(e.request).then(m => m || caches.match('./'))));
});
self.addEventListener('message', e => { if (e.data === 'skipWaiting') self.skipWaiting(); });
