const $ = (selector, scope = document) => scope.querySelector(selector);
const $$ = (selector, scope = document) => [...scope.querySelectorAll(selector)];

const toast = $('#toast');
let toastTimer;
function showToast(message) {
  if (!toast) return;
  toast.textContent = message;
  toast.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => toast.classList.remove('show'), 3000);
}

const menuToggle = $('#menuToggle');
const mainNav = $('#mainNav');
menuToggle?.addEventListener('click', () => {
  const open = mainNav.classList.toggle('open');
  menuToggle.setAttribute('aria-expanded', String(open));
});
$$('#mainNav a').forEach(link => link.addEventListener('click', () => {
  mainNav?.classList.remove('open');
  menuToggle?.setAttribute('aria-expanded', 'false');
}));

let selectedCategory = 'Básico';
let selectedPrice = 68;

$$('.category-card').forEach(card => card.addEventListener('click', () => {
  $$('.category-card').forEach(item => item.classList.remove('selected'));
  card.classList.add('selected');
  selectedCategory = card.dataset.category || 'Básico';
  selectedPrice = Number(card.dataset.price || 68);
  updateRiderEstimate();
  showToast(`${selectedCategory} seleccionado. Tarifa base desde $${selectedPrice}.`);
}));

const DELICIAS = [28.1902, -105.4701];
const heroRoute = [
  [28.1940,-105.4745],[28.1934,-105.4703],[28.1919,-105.4686],[28.1896,-105.4673],
  [28.1877,-105.4659],[28.1857,-105.4630],[28.1841,-105.4596],[28.1858,-105.4579],
  [28.1884,-105.4592],[28.1907,-105.4622],[28.1923,-105.4664],[28.1940,-105.4745]
];

const locations = {
  centro: { label:'Plaza de la República', point:[28.19065,-105.47045] },
  oriente: { label:'Col. Revolución', point:[28.19015,-105.45785] },
  poniente: { label:'Parque Fundadores', point:[28.19175,-105.4812] },
  tec: { label:'Tecnológico de Delicias', point:[28.18415,-105.4593], extra:0 },
  terminal: { label:'Terminal de Autobuses', point:[28.19265,-105.4671], extra:8 },
  hospital: { label:'Hospital Regional', point:[28.18145,-105.4750], extra:14 },
  meoqui: { label:'Meoqui, Chihuahua', point:[28.27215,-105.48075], extra:92 }
};

function interpolateRoute(a, b, bends = 5) {
  const points = [a];
  for (let i = 1; i < bends; i += 1) {
    const t = i / bends;
    const lat = a[0] + (b[0] - a[0]) * t;
    const lng = a[1] + (b[1] - a[1]) * t;
    const offset = Math.sin(t * Math.PI) * 0.00125;
    points.push([lat + offset * (i % 2 ? 1 : -0.55), lng + offset * 0.7]);
  }
  points.push(b);
  return points;
}

const carSvg = `
  <div class="map-car-marker" aria-label="Unidad Yavoi">
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M4 14.5V12l2.1-5.1A2 2 0 0 1 8 5.7h8a2 2 0 0 1 1.9 1.2L20 12v2.5M5.5 14.5h13M7 12h10M6.5 18.3v-2.1M17.5 18.3v-2.1" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>
      <circle cx="7" cy="14.5" r="1"/><circle cx="17" cy="14.5" r="1"/>
    </svg>
  </div>`;

function carIcon() {
  return L.divIcon({ className:'', html:carSvg, iconSize:[46,46], iconAnchor:[23,23] });
}

function baseMap(id, zoom = 14, interactive = true) {
  const element = document.getElementById(id);
  if (!element || typeof L === 'undefined') return null;
  const map = L.map(id, {
    zoomControl: interactive,
    scrollWheelZoom: false,
    dragging: interactive,
    doubleClickZoom: interactive,
    attributionControl: true
  }).setView(DELICIAS, zoom);
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom:19,
    attribution:'&copy; OpenStreetMap'
  }).addTo(map);
  if (interactive && map.zoomControl) map.zoomControl.setPosition('bottomright');
  return map;
}

function drawRoute(map, points, color = '#06192c', weight = 6) {
  if (!map) return null;
  return L.polyline(points, { color, weight, opacity:.9, lineCap:'round', lineJoin:'round' }).addTo(map);
}

function addEndpoints(map, points) {
  if (!map || !points?.length) return [];
  const start = L.circleMarker(points[0], { radius:7, color:'#fff', weight:3, fillColor:'#1f7aff', fillOpacity:1 }).addTo(map);
  const end = L.circleMarker(points[points.length - 1], { radius:7, color:'#fff', weight:3, fillColor:'#ff6a00', fillOpacity:1 }).addTo(map);
  return [start, end];
}

function stopMarker(marker) {
  if (!marker) return;
  marker._yavoiAnimation = (marker._yavoiAnimation || 0) + 1;
}

function animateMarker(marker, points, duration = 9000, loop = false, progressCallback = null, completeCallback = null) {
  if (!marker || !points || points.length < 2) return;
  stopMarker(marker);
  const token = marker._yavoiAnimation;
  const segments = points.length - 1;
  let startTime = null;

  function frame(timestamp) {
    if (marker._yavoiAnimation !== token) return;
    if (!startTime) startTime = timestamp;
    const raw = (timestamp - startTime) / duration;
    const normalized = loop ? raw % 1 : Math.min(raw, 1);
    const scaled = normalized * segments;
    const index = Math.min(Math.floor(scaled), segments - 1);
    const local = scaled - index;
    const a = points[index];
    const b = points[index + 1];
    const lat = a[0] + (b[0] - a[0]) * local;
    const lng = a[1] + (b[1] - a[1]) * local;
    marker.setLatLng([lat,lng]);
    if (typeof progressCallback === 'function') progressCallback(normalized);
    if (!loop && raw >= 1) {
      if (typeof completeCallback === 'function') completeCallback();
      return;
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

function setupLoopMap(id, points, duration, progressCallback = null) {
  const map = baseMap(id, 14, false);
  if (!map) return { map:null, marker:null };
  drawRoute(map, points);
  addEndpoints(map, points);
  map.fitBounds(points, { padding:[36,36] });
  const marker = L.marker(points[0], { icon:carIcon(), zIndexOffset:1000 }).addTo(map);
  animateMarker(marker, points, duration, true, progressCallback);
  return { map, marker };
}

let heroMap, previewMap, securityMap, riderMap, driverMap;
let heroCar, previewCar, securityCar, riderCar, driverCar;
let riderRouteLine, riderEndpointLayers = [];
let driverRouteLine, driverEndpointLayers = [];

if (typeof L !== 'undefined') {
  ({ map:heroMap, marker:heroCar } = setupLoopMap('heroMap', heroRoute, 18000, progress => {
    const eta = $('#heroEta');
    if (eta) eta.textContent = `${Math.max(3, Math.round(9 - progress * 6))} min`;
  }));

  ({ map:previewMap, marker:previewCar } = setupLoopMap('previewMap', heroRoute.slice(1,10), 15000, progress => {
    const eta = $('#previewEta');
    const distance = $('#previewDistance');
    if (eta) eta.textContent = `Llega en ${Math.max(2, Math.round(5 - progress * 3))} min`;
    if (distance) distance.textContent = `${Math.max(.3, 1.4 - progress).toFixed(1)} km`;
  }));

  ({ map:securityMap, marker:securityCar } = setupLoopMap('securityMap', heroRoute.slice(2,11), 17000));

  riderMap = baseMap('riderMap', 14, true);
  driverMap = baseMap('driverMap', 14, true);
  prepareRiderRoute();
  prepareDriverRoute();
} else {
  showToast('Los mapas requieren conexión a internet para mostrar OpenStreetMap.');
}

function currentRiderPoints() {
  const originKey = $('#riderOrigin')?.value || 'centro';
  const destinationKey = $('#riderDestination')?.value || 'tec';
  const origin = locations[originKey] || locations.centro;
  const destination = locations[destinationKey] || locations.tec;
  const bends = destinationKey === 'meoqui' ? 8 : 5;
  return { origin, destination, points:interpolateRoute(origin.point, destination.point, bends) };
}

function clearRouteLayers(map, line, endpoints) {
  if (map && line) map.removeLayer(line);
  endpoints.forEach(layer => map?.removeLayer(layer));
}

function prepareRiderRoute() {
  if (!riderMap) return;
  clearRouteLayers(riderMap, riderRouteLine, riderEndpointLayers);
  if (riderCar) riderMap.removeLayer(riderCar);
  const { points } = currentRiderPoints();
  riderRouteLine = drawRoute(riderMap, points);
  riderEndpointLayers = addEndpoints(riderMap, points);
  riderMap.fitBounds(points, { padding:[42,42] });
  const nearby = [points[0][0] + .0042, points[0][1] - .0045];
  riderCar = L.marker(nearby, { icon:carIcon(), zIndexOffset:1000, opacity:0 }).addTo(riderMap);
}

function updateRiderEstimate() {
  const destinationKey = $('#riderDestination')?.value || 'tec';
  const extra = locations[destinationKey]?.extra || 0;
  const price = selectedPrice + extra;
  const fare = $('#riderFare');
  const simPrice = $('#simPrice');
  const simCategory = $('#simCategory');
  if (fare) fare.textContent = `$${price}`;
  if (simPrice) simPrice.textContent = `$${price}`;
  if (simCategory) simCategory.textContent = selectedCategory;
  return price;
}

$('#riderOrigin')?.addEventListener('change', () => { resetRider(false); prepareRiderRoute(); });
$('#riderDestination')?.addEventListener('change', () => { resetRider(false); prepareRiderRoute(); updateRiderEstimate(); });

let riderPhase = 0;
let riderBusy = false;

function setRiderUI({ state, kicker, title, action, disabled = false }) {
  if ($('#riderPhoneState')) $('#riderPhoneState').textContent = state;
  if ($('#riderKicker')) $('#riderKicker').textContent = kicker;
  if ($('#riderTitle')) $('#riderTitle').textContent = title;
  const button = $('#riderAction');
  if (button) { button.textContent = action; button.disabled = disabled; button.style.opacity = disabled ? '.65' : '1'; }
}

function resetRider(rebuild = true) {
  riderPhase = 0;
  riderBusy = false;
  $('#assignedDriver')?.classList.add('hidden');
  setRiderUI({ state:'Listo', kicker:'SOLICITAR VIAJE', title:'¿A dónde vamos?', action:'Solicitar Yavoi!' });
  if (riderCar) { stopMarker(riderCar); riderCar.setOpacity(0); }
  updateRiderEstimate();
  if (rebuild) prepareRiderRoute();
}

$('#resetRider')?.addEventListener('click', () => resetRider(true));

$('#riderAction')?.addEventListener('click', () => {
  if (riderBusy) return;
  const { origin, destination, points } = currentRiderPoints();
  const action = $('#riderAction');

  if (riderPhase === 0) {
    riderBusy = true;
    setRiderUI({ state:'Buscando', kicker:'CONECTANDO', title:'Buscando un conductor cercano', action:'Buscando conductor', disabled:true });
    const approachStart = [origin.point[0] + .0042, origin.point[1] - .0045];
    const approach = interpolateRoute(approachStart, origin.point, 4);
    riderCar.setLatLng(approachStart).setOpacity(1);
    setTimeout(() => {
      $('#assignedDriver')?.classList.remove('hidden');
      setRiderUI({ state:'Asignado', kicker:'CONDUCTOR EN CAMINO', title:'Laura llega en pocos minutos', action:'Unidad acercándose', disabled:true });
      animateMarker(riderCar, approach, 3600, false, progress => {
        const eta = $('#riderEta');
        if (eta) eta.textContent = `${Math.max(1, Math.round(4 - progress * 3))} min`;
      }, () => {
        riderBusy = false;
        riderPhase = 1;
        setRiderUI({ state:'Llegó', kicker:'UNIDAD EN EL PUNTO', title:'Tu Yavoi! ya llegó', action:'Iniciar viaje' });
      });
    }, 900);
    return;
  }

  if (riderPhase === 1) {
    riderBusy = true;
    setRiderUI({ state:'En viaje', kicker:'VIAJE EN CURSO', title:`Rumbo a ${destination.label}`, action:'Ruta monitoreada', disabled:true });
    animateMarker(riderCar, points, destination.label.includes('Meoqui') ? 7800 : 5600, false, progress => {
      const eta = $('#riderEta');
      if (eta) eta.textContent = `${Math.max(1, Math.round((destination.label.includes('Meoqui') ? 18 : 9) * (1-progress)))} min`;
    }, () => {
      riderBusy = false;
      riderPhase = 2;
      setRiderUI({ state:'Llegaste', kicker:'DESTINO ALCANZADO', title:'Llegaste a tu destino', action:'Finalizar y calificar' });
    });
    return;
  }

  if (riderPhase === 2) {
    riderPhase = 3;
    setRiderUI({ state:'Completado', kicker:'VIAJE COMPLETADO', title:'Gracias por viajar con Yavoi!', action:'Solicitar otro viaje' });
    showToast('Viaje completado. Tu experiencia quedó lista para calificación.');
    return;
  }

  resetRider(true);
});

function driverTripPoints() {
  const pickup = [28.19065,-105.47045];
  const destination = [28.19015,-105.45785];
  return {
    approach: interpolateRoute([28.1960,-105.4760], pickup, 5),
    trip: interpolateRoute(pickup, destination, 6)
  };
}

function prepareDriverRoute() {
  if (!driverMap) return;
  clearRouteLayers(driverMap, driverRouteLine, driverEndpointLayers);
  if (driverCar) driverMap.removeLayer(driverCar);
  const { approach, trip } = driverTripPoints();
  const full = [...approach, ...trip.slice(1)];
  driverRouteLine = drawRoute(driverMap, full);
  driverEndpointLayers = addEndpoints(driverMap, full);
  driverMap.fitBounds(full, { padding:[38,38] });
  driverCar = L.marker(approach[0], { icon:carIcon(), zIndexOffset:1000 }).addTo(driverMap);
}

let driverPhase = 0;
let driverBusy = false;
let driverCountdownValue = 12;
let countdownTimer;

function startDriverCountdown() {
  clearInterval(countdownTimer);
  driverCountdownValue = 12;
  const label = $('#driverCountdown');
  if (label) label.textContent = '12 s';
  countdownTimer = setInterval(() => {
    if (driverPhase !== 0) { clearInterval(countdownTimer); return; }
    driverCountdownValue = Math.max(1, driverCountdownValue - 1);
    if (label) label.textContent = `${driverCountdownValue} s`;
  }, 1000);
}

function setDriverUI({ status, kicker, action, help, disabled = false }) {
  if ($('#driverPhoneStatus')) $('#driverPhoneStatus').textContent = status;
  if ($('#driverKicker')) $('#driverKicker').textContent = kicker;
  if ($('#driverHelp') && help) $('#driverHelp').textContent = help;
  const button = $('#driverAction');
  if (button) { button.textContent = action; button.disabled = disabled; button.style.opacity = disabled ? '.65' : '1'; }
}

function resetDriver() {
  driverPhase = 0;
  driverBusy = false;
  prepareDriverRoute();
  setDriverUI({ status:'Conectado', kicker:'NUEVO SERVICIO', action:'Aceptar servicio', help:'Acepta el servicio para activar la navegación hacia el pasajero. Después podrás marcar llegada, iniciar el viaje y finalizarlo.' });
  if ($('#driverPrice')) $('#driverPrice').textContent = '$86';
  startDriverCountdown();
}

$('#resetDriver')?.addEventListener('click', resetDriver);

$('#driverAction')?.addEventListener('click', () => {
  if (driverBusy) return;
  const { approach, trip } = driverTripPoints();

  if (driverPhase === 0) {
    clearInterval(countdownTimer);
    driverBusy = true;
    setDriverUI({ status:'En ruta', kicker:'SERVICIO ACEPTADO', action:'Navegando al pasajero', disabled:true, help:'La unidad se dirige al punto de recogida. El pasajero puede seguir el avance en su mapa.' });
    animateMarker(driverCar, approach, 4200, false, null, () => {
      driverBusy = false;
      driverPhase = 1;
      setDriverUI({ status:'En punto', kicker:'PUNTO DE RECOGIDA', action:'Marcar llegada', help:'Llegaste al origen. Marca la llegada para avisar al pasajero y habilitar el inicio del viaje.' });
    });
    return;
  }

  if (driverPhase === 1) {
    driverPhase = 2;
    setDriverUI({ status:'Pasajero listo', kicker:'PASAJERO A BORDO', action:'Iniciar viaje', help:'Cuando el pasajero esté a bordo, inicia el viaje para activar el seguimiento completo del recorrido.' });
    return;
  }

  if (driverPhase === 2) {
    driverBusy = true;
    setDriverUI({ status:'En viaje', kicker:'VIAJE EN CURSO', action:'Navegación activa', disabled:true, help:'El servicio está en curso. La ruta y la unidad permanecen visibles durante el trayecto.' });
    animateMarker(driverCar, trip, 5200, false, null, () => {
      driverBusy = false;
      driverPhase = 3;
      setDriverUI({ status:'Destino', kicker:'DESTINO ALCANZADO', action:'Finalizar servicio', help:'Llegaste al destino. Finaliza para registrar el servicio y actualizar ganancias.' });
    });
    return;
  }

  if (driverPhase === 3) {
    driverPhase = 4;
    const earnings = $('#driverEarnings');
    if (earnings) earnings.textContent = '$770';
    setDriverUI({ status:'Completado', kicker:'SERVICIO COMPLETADO', action:'Nuevo servicio', help:'Servicio completado. Se actualizó el resumen del día y el conductor queda listo para una nueva solicitud.' });
    showToast('Servicio finalizado. Ganancias del día actualizadas.');
    return;
  }

  resetDriver();
});

$$('[data-sim]').forEach(button => button.addEventListener('click', () => {
  $$('[data-sim]').forEach(item => item.classList.remove('active'));
  button.classList.add('active');
  const rider = $('#riderSim');
  const driver = $('#driverSim');
  const showRider = button.dataset.sim === 'rider';
  rider?.classList.toggle('active', showRider);
  driver?.classList.toggle('active', !showRider);
  setTimeout(() => {
    riderMap?.invalidateSize();
    driverMap?.invalidateSize();
  }, 180);
}));

$$('.regional-destinations button').forEach(button => button.addEventListener('click', () => {
  const city = button.dataset.city;
  if (city === 'Meoqui') {
    const destination = $('#riderDestination');
    if (destination) destination.value = 'meoqui';
    resetRider(true);
    updateRiderEstimate();
    $('#simulador')?.scrollIntoView({ behavior:'smooth' });
    showToast('Meoqui seleccionado como destino regional.');
  } else {
    showToast(`${city}: ruta regional disponible como concepto de expansión Yavoi!.`);
  }
}));

updateRiderEstimate();
startDriverCountdown();

let resizeTimer;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    heroMap?.invalidateSize();
    previewMap?.invalidateSize();
    securityMap?.invalidateSize();
    riderMap?.invalidateSize();
    driverMap?.invalidateSize();
  }, 160);
});

// Escala visual de marca Yavoi! y ajuste del mensaje principal.
function enhanceYavoiBranding() {
  const heroTitle = $('.hero-copy h1');
  if (heroTitle) {
    heroTitle.innerHTML = 'Tu Ciudad!<br />Tu Gente!<br /><img class="hero-wordmark-runtime" src="assets/yavoi-logo.png" alt="Yavoi!" />';
  }

  if (!document.getElementById('yavoi-brand-scale')) {
    const style = document.createElement('style');
    style.id = 'yavoi-brand-scale';
    style.textContent = `
      .nav-shell { min-height: 112px; height: auto; }
      .brand { min-width: 245px; }
      .brand img { width: 228px !important; height: 86px !important; object-fit: contain; object-position: left center; }
      .app-brand-row { min-height: 86px !important; height: auto !important; }
      .app-brand-row img { width: 168px !important; height: 66px !important; object-fit: contain; object-position: left center; }
      .hero-copy h1 { line-height: .94; }
      .hero-wordmark-runtime { display:block; width:auto !important; height:1.05em !important; max-width:100% !important; object-fit:contain; object-position:left center; margin:.08em 0 0; }
      .final-card > img { width:min(390px,72vw) !important; height:auto !important; max-height:none !important; margin-inline:auto; }
      .footer-brand img { width:245px !important; height:auto !important; max-height:none !important; }
      @media (max-width: 1100px) {
        .brand { min-width: 205px; }
        .brand img { width:195px !important; height:74px !important; }
        .app-brand-row img { width:150px !important; height:58px !important; }
      }
      @media (max-width: 760px) {
        .nav-shell { min-height: 92px; }
        .brand { min-width: 0; }
        .brand img { width:178px !important; height:68px !important; }
        .hero-wordmark-runtime { height:.98em !important; }
        .app-brand-row img { width:142px !important; height:56px !important; }
        .footer-brand img { width:210px !important; }
      }
      @media (max-width: 430px) {
        .brand img { width:158px !important; height:62px !important; }
        .hero-wordmark-runtime { height:.92em !important; }
      }
    `;
    document.head.appendChild(style);
  }
}

enhanceYavoiBranding();
