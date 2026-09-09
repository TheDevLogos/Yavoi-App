const $ = (s, scope = document) => scope.querySelector(s);
const $$ = (s, scope = document) => [...scope.querySelectorAll(s)];

const toast = $('#toast');
let toastTimer;
function showToast(message) {
  if (!toast) return;
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 3200);
}

// Navegación móvil
const menuToggle = $('#menuToggle');
const mainNav = $('#mainNav');
menuToggle?.addEventListener('click', () => {
  const isOpen = mainNav.classList.toggle('open');
  menuToggle.setAttribute('aria-expanded', String(isOpen));
});
$$('#mainNav a').forEach(a => a.addEventListener('click', () => {
  mainNav?.classList.remove('open');
  menuToggle?.setAttribute('aria-expanded', 'false');
}));

// Tabs de reservación rápida
$$('[data-book-tab]').forEach(btn => btn.addEventListener('click', () => {
  $$('[data-book-tab]').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  showToast(btn.dataset.bookTab === 'scheduled' ? 'Modo viaje programado seleccionado' : 'Modo viaje inmediato seleccionado');
}));

// Categorías
let selectedCategory = 'Básico';
let selectedPrice = 68;
$$('.category-card').forEach(card => card.addEventListener('click', () => {
  $$('.category-card').forEach(c => c.classList.remove('selected'));
  card.classList.add('selected');
  selectedCategory = card.dataset.category;
  selectedPrice = Number(card.dataset.price);
  const categoryLabel = $('#selectedCategory');
  const priceLabel = $('#selectedPrice');
  if (categoryLabel) categoryLabel.textContent = selectedCategory;
  if (priceLabel) priceLabel.textContent = `$${selectedPrice}`;
  showToast(`${selectedCategory} seleccionado · desde $${selectedPrice}`);
}));

$('#quickQuoteBtn')?.addEventListener('click', () => {
  const destination = $('#destinationInput')?.value?.trim() || 'tu destino';
  showToast(`Opciones estimadas para ${destination}: desde $${selectedPrice}`);
  document.querySelector('#simulador')?.scrollIntoView({ behavior: 'smooth' });
}));

// Cambio usuario / conductor
$$('[data-sim]').forEach(btn => btn.addEventListener('click', () => {
  $$('[data-sim]').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  const userView = $('#userSim');
  const driverView = $('#driverSim');
  if (btn.dataset.sim === 'user') {
    userView?.classList.add('active');
    driverView?.classList.remove('active');
    setTimeout(() => simMap?.invalidateSize(), 120);
  } else {
    driverView?.classList.add('active');
    userView?.classList.remove('active');
  }
}));

// Mapas Leaflet + auto animado
const DELICIAS = [28.1901, -105.4701];
const route = [
  [28.1937, -105.4724],
  [28.1929, -105.4682],
  [28.1908, -105.4668],
  [28.1882, -105.4689],
  [28.1858, -105.4651],
  [28.1836, -105.4619],
  [28.1864, -105.4584],
  [28.1897, -105.4596],
  [28.1916, -105.4638]
];

function carIcon() {
  return L.divIcon({
    className: '',
    html: '<div class="yavoi-car-icon" aria-label="Unidad Yavoi">🚙</div>',
    iconSize: [42, 42],
    iconAnchor: [21, 21]
  });
}

function baseMap(id, zoom = 14) {
  if (typeof L === 'undefined' || !document.getElementById(id)) return null;
  const map = L.map(id, { zoomControl: false, scrollWheelZoom: false, attributionControl: true }).setView(DELICIAS, zoom);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; OpenStreetMap'
  }).addTo(map);
  L.control.zoom({ position: 'bottomright' }).addTo(map);
  return map;
}

function addRoute(map, withCar = true) {
  if (!map) return null;
  L.polyline(route, { color: '#06192c', weight: 6, opacity: .88, lineCap: 'round' }).addTo(map);
  L.circleMarker(route[0], { radius: 7, color: '#fff', weight: 3, fillColor: '#1f7aff', fillOpacity: 1 }).addTo(map);
  L.circleMarker(route[route.length - 1], { radius: 7, color: '#fff', weight: 3, fillColor: '#ff6a00', fillOpacity: 1 }).addTo(map);
  if (!withCar) return null;
  return L.marker(route[0], { icon: carIcon(), zIndexOffset: 1000 }).addTo(map);
}

function animateMarker(marker, points, duration = 16500) {
  if (!marker || !points?.length) return;
  let start = null;
  const segments = points.length - 1;
  function frame(timestamp) {
    if (!start) start = timestamp;
    const elapsed = (timestamp - start) % duration;
    const progress = elapsed / duration;
    const scaled = progress * segments;
    const i = Math.min(Math.floor(scaled), segments - 1);
    const local = scaled - i;
    const a = points[i];
    const b = points[i + 1];
    const lat = a[0] + (b[0] - a[0]) * local;
    const lng = a[1] + (b[1] - a[1]) * local;
    marker.setLatLng([lat, lng]);
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

let heroMap, phoneMap, simMap, simCar;
if (typeof L !== 'undefined') {
  heroMap = baseMap('heroMap', 14);
  const heroCar = addRoute(heroMap, true);
  if (heroMap) {
    heroMap.fitBounds(route, { padding: [42, 42] });
    animateMarker(heroCar, route, 18000);
  }

  phoneMap = baseMap('phoneMap', 14);
  const phoneCar = addRoute(phoneMap, true);
  if (phoneMap) {
    phoneMap.fitBounds(route, { padding: [18, 18] });
    animateMarker(phoneCar, route, 15000);
  }

  simMap = baseMap('simMap', 14);
  simCar = addRoute(simMap, true);
  if (simMap) simMap.fitBounds(route, { padding: [45, 45] });
} else {
  showToast('El mapa interactivo requiere conexión a internet para cargar OpenStreetMap.');
}

// Simulación de viaje de usuario
let rideSimulationRunning = false;
$('#simulateRideBtn')?.addEventListener('click', () => {
  if (rideSimulationRunning) return;
  rideSimulationRunning = true;
  const btn = $('#simulateRideBtn');
  const status = $('#routeStatus');
  const title = $('#simTitle');
  const step = $('#simStepContent');

  const phases = [
    { delay: 0, status: 'Buscando conductor cercano…', title: 'Buscando tu Yavoi!', button: 'Buscando…' },
    { delay: 1600, status: 'Carlos M. aceptó · llega en 4 min', title: '¡Conductor encontrado!', button: 'Conductor asignado' },
    { delay: 3600, status: 'Unidad acercándose · 2 min', title: 'Tu conductor va en camino', button: 'Ver recorrido' },
    { delay: 5900, status: 'Viaje iniciado · ruta monitoreada', title: 'Viaje en curso', button: 'Compartir viaje' },
    { delay: 9000, status: 'Destino alcanzado', title: '¡Llegaste!', button: 'Calificar experiencia' }
  ];

  phases.forEach((phase, idx) => setTimeout(() => {
    if (status) status.textContent = phase.status;
    if (title) title.textContent = phase.title;
    if (btn) btn.textContent = phase.button;

    if (idx === 1 && step) {
      step.innerHTML = `
        <div class="selected-service"><span>🚙</span><div><small>Conductor</small><strong>Carlos M. · ★ 4.9</strong></div><strong>4 min</strong></div>
        <div class="selected-service"><span>🔎</span><div><small>Unidad</small><strong>Nissan Versa · YV-214</strong></div><strong>${selectedCategory}</strong></div>`;
    }
    if (idx === 3 && simCar) animateMarker(simCar, route, 5200);
    if (idx === phases.length - 1) {
      rideSimulationRunning = false;
      if (btn) {
        btn.onclick = () => showToast('Gracias por probar Yavoi! ★★★★★');
      }
    }
  }, phase.delay));
}));

// Simulación conductor
$('#acceptRideBtn')?.addEventListener('click', (e) => {
  const btn = e.currentTarget;
  btn.textContent = 'Servicio aceptado ✓';
  btn.disabled = true;
  btn.style.opacity = '.72';
  showToast('Servicio asignado. Ruta hacia el pasajero activada.');
  setTimeout(() => {
    btn.textContent = 'Iniciar navegación';
    btn.disabled = false;
    btn.style.opacity = '1';
  }, 2600);
});

// Botones de destinos regionales
$$('.destination-list button').forEach(btn => btn.addEventListener('click', () => {
  const city = $('strong', btn)?.textContent || 'destino';
  showToast(`Ruta regional a ${city}: próximamente en el cotizador.`);
}));

// Ajustes de mapa al cambiar tamaño
let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    heroMap?.invalidateSize();
    phoneMap?.invalidateSize();
    simMap?.invalidateSize();
  }, 140);
});
