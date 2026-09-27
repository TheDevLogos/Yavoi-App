const CACHE = "yavoi-shell-v6";
const CORE = [
  "/",
  "/portal.html",
  "/offline.html",
  "/manifest.webmanifest",
  "/assets/yavoi-logo.png",
  "/assets/map-origin.svg",
  "/assets/map-destination.svg",
  "/assets/map-car-top.svg",
  "/fonts/nunito-latin.woff2",
  "/fonts/inter-latin.woff2",
  "/icons/yavoi-192.png",
  "/icons/yavoi-512.png",
  "/icons/yavoi-maskable-512.png",
  "/icons/apple-touch-icon.png"
];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(CACHE).then((cache) => cache.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== location.origin || url.pathname.startsWith("/functions/") || url.pathname.includes("supabase")) return;

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).then((response) => {
        const copy = response.clone();
        caches.open(CACHE).then((cache) => cache.put(request, copy));
        return response;
      }).catch(async () => (await caches.match(request)) || caches.match("/offline.html")),
    );
    return;
  }

  if (["style", "script", "image", "font"].includes(request.destination)) {
    event.respondWith(
      caches.match(request).then((cached) => cached || fetch(request).then((response) => {
        if (response.ok) caches.open(CACHE).then((cache) => cache.put(request, response.clone()));
        return response;
      })),
    );
  }
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const target = event.notification.data?.target || "home";
  event.waitUntil(
    clients.matchAll({ type: "window", includeUncontrolled: true }).then((windows) => {
      const existing = windows[0];
      if (existing) return existing.focus().then(() => existing.navigate(`/portal.html#${target}`));
      return clients.openWindow(`/portal.html#${target}`);
    }),
  );
});

// Las suscripciones Web Push llegan aquí incluso si la PWA está en segundo
// plano. El servidor entrega el contenido y la pantalla de destino, mientras
// que este controlador conserva una apertura segura dentro de Yavoi!.
self.addEventListener("push", (event) => {
  let payload = {};
  try { payload = event.data ? event.data.json() : {}; } catch { payload = { body: event.data?.text?.() || "" }; }
  const title = payload.title || "Yavoi!";
  const options = {
    body: payload.body || "Tienes una actualización de Yavoi!.",
    icon: "/icons/yavoi-192.png",
    badge: "/icons/yavoi-maskable-512.png",
    tag: payload.tag || "yavoi-update",
    renotify: Boolean(payload.renotify),
    data: { target: payload.target || "home" },
  };
  event.waitUntil(self.registration.showNotification(title, options));
});
