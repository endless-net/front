'use strict';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil((async () => {
    const names = await caches.keys();
    await Promise.all(names
      .filter((name) => name === 'flutter-app-cache' ||
        name === 'flutter-app-manifest' ||
        name === 'flutter-temp-cache' ||
        name.startsWith('flutter-'))
      .map((name) => caches.delete(name)));

    await self.clients.claim();
    await self.registration.unregister();

    const clients = await self.clients.matchAll({
      type: 'window',
      includeUncontrolled: true
    });
    for (const client of clients) {
      if ('navigate' in client) {
        client.navigate(client.url);
      }
    }
  })());
});