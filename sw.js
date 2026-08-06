// C-Direct — service worker minimal pour les notifications Web Push.
// N'intercepte AUCUNE requête réseau et ne fait AUCUN cache offline :
// son seul rôle est de recevoir les événements push et d'afficher la
// notification, puis de gérer le clic dessus. Voir parametres.html
// (abonnement) et workers/c-direct-sms (envoi, sql/49).

self.addEventListener('install', () => { self.skipWaiting(); });
self.addEventListener('activate', event => { event.waitUntil(self.clients.claim()); });

self.addEventListener('push', event => {
  let data = {};
  try{ data = event.data ? event.data.json() : {}; }
  catch(e){ data = { title: 'C-Direct', body: event.data ? event.data.text() : '' }; }

  const titre = data.title || 'C-Direct';
  const options = {
    body: data.body || '',
    icon: data.icon || '/logo-balance-final.png',
    badge: data.badge || '/logo-balance-final.png',
    data: { url: data.url || '/' }
  };
  event.waitUntil(self.registration.showNotification(titre, options));
});

self.addEventListener('notificationclick', event => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(list => {
      for(const c of list){ if(c.url === url && 'focus' in c) return c.focus(); }
      if(self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
