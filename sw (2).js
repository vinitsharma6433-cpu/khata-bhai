const CACHE_NAME = 'khata-bhai-v3';
const ASSETS = [
  './',
  './KhataBhai.html',
  './manifest.json',
  './icon-192.png',
  './icon-512.png'
];

// Install - सब files cache करो
self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME).then(cache => {
      return cache.addAll(ASSETS);
    })
  );
  self.skipWaiting();
});

// Activate - पुरानी cache हटाओ
self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys().then(keys => {
      return Promise.all(
        keys.filter(key => key !== CACHE_NAME)
            .map(key => caches.delete(key))
      );
    })
  );
  self.clients.claim();
});

// Fetch - पहले cache से दो, फिर network से
self.addEventListener('fetch', event => {
  event.respondWith(
    caches.match(event.request).then(cached => {
      if (cached) return cached;
      return fetch(event.request).then(response => {
        if (!response || response.status !== 200) return response;
        const clone = response.clone();
        caches.open(CACHE_NAME).then(cache => {
          cache.put(event.request, clone);
        });
        return response;
      }).catch(() => {
        return caches.match('./KhataBhai.html');
      });
    })
  );
});

// Background sync
self.addEventListener('sync', event => {
  console.log('Background sync:', event.tag);
});

// Push notifications ready
self.addEventListener('push', event => {
  const data = event.data ? event.data.text() : 'Khata Bhai Update';
  event.waitUntil(
    self.registration.showNotification('Khata Bhai', {
      body: data,
      icon: './icon-192.png'
    })
  );
});
