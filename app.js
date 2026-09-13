import L from 'leaflet';
import 'leaflet/dist/leaflet.css';
import { fallbackStreetRoute, routeKey, routeMeasurements, routePosition, travelledPoints } from './src/landing-route.js';
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
let selectedPrice = 65;

$$('.category-card').forEach(card => card.addEventListener('click', () => {
  $$('.category-card').forEach(item => item.classList.remove('selected'));
  card.classList.add('selected');
  selectedCategory = card.dataset.category || 'Básico';
  selectedPrice = Number(card.dataset.price || 65);
  updateRiderEstimate();
  showToast(`${selectedCategory} seleccionado. Estimado de viaje actualizado a $${selectedPrice}.`);
}));

const DELICIAS = [28.1902, -105.4701];
const DEMO_DRIVER_START = [28.1960, -105.4760];
const ROAD_ROUTER = 'https://router.project-osrm.org/route/v1/driving';
const routeCache = new Map();

const locations = {
  centro: { label:'Plaza de la República', point:[28.19065,-105.47045] },
  oriente: { label:'Col. Revolución', point:[28.19015,-105.45785] },
  poniente: { label:'Parque Fundadores', point:[28.19175,-105.4812] },
  tec: { label:'Tecnológico de Delicias', point:[28.18415,-105.4593], extra:0 },
  terminal: { label:'Terminal de Autobuses', point:[28.19265,-105.4671], extra:8 },
  hospital: { label:'Hospital Regional', point:[28.18145,-105.4750], extra:14 },
  meoqui: { label:'Meoqui, Chihuahua', point:[28.27215,-105.48075], extra:92 }
};

async function roadRoute(a, b) {
  const key = routeKey(a, b);
  if (!routeCache.has(key)) {
    routeCache.set(key, (async () => {
      const coordinates = `${a[1]},${a[0]};${b[1]},${b[0]}`;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8000);
      let response;
      try {
        response = await fetch(`${ROAD_ROUTER}/${coordinates}?overview=full&geometries=geojson&steps=false`, { signal:controller.signal });
      } finally {
        clearTimeout(timeout);
      }
      if (!response.ok) throw new Error('No fue posible calcular la ruta vial de demostración.');
      const payload = await response.json();
      const points = payload.routes?.[0]?.geometry?.coordinates?.map(([lng, lat]) => [Number(lat), Number(lng)]);
      if (!Array.isArray(points) || points.length < 2) throw new Error('La ruta vial no contiene un recorrido válido.');
      return points;
    })().catch(() => fallbackStreetRoute(a, b)));
  }
  return routeCache.get(key);
}

const carSvg = `<div class="map-car-marker" aria-label="Unidad Yavoi"><img src="/assets/map-car-top.svg" alt=""></div>`;

function carIcon() {
  return L.divIcon({ className:'', html:carSvg, iconSize:[46,62], iconAnchor:[23,31] });
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

function drawRoute(map, points, color = '#123a5b', weight = 6) {
  if (!map) return null;
  const casing = L.polyline(points, { color:'#fff', weight:weight + 5, opacity:.92, lineCap:'round', lineJoin:'round', interactive:false });
  const route = L.polyline(points, { color, weight, opacity:.92, lineCap:'round', lineJoin:'round', interactive:false });
  return L.layerGroup([casing, route]).addTo(map);
}

function drawTravelledRoute(map, point) {
  return L.polyline([point, point], {
    color:'#ff6a0a',
    weight:6,
    opacity:1,
    lineCap:'round',
    lineJoin:'round',
    interactive:false
  }).addTo(map);
}

function fitRouteForPhone(map, points) {
  map?.fitBounds(points, {
    paddingTopLeft:[18,18],
    paddingBottomRight:[18,155],
    maxZoom:15
  });
}

function addEndpoints(map, points) {
  if (!map || !points?.length) return [];
  const startIcon = L.icon({ iconUrl:'/assets/map-origin.svg', iconSize:[42,50], iconAnchor:[21,46], tooltipAnchor:[0,-43] });
  const endIcon = L.icon({ iconUrl:'/assets/map-destination.svg', iconSize:[42,50], iconAnchor:[21,46], tooltipAnchor:[0,-43] });
  const start = L.marker(points[0], { icon:startIcon, zIndexOffset:1000 }).bindTooltip('Punto de partida').addTo(map);
  const end = L.marker(points[points.length - 1], { icon:endIcon, zIndexOffset:1000 }).bindTooltip('Destino').addTo(map);
  return [start, end];
}

function stopMarker(marker) {
  if (!marker) return;
  marker._yavoiAnimation = (marker._yavoiAnimation || 0) + 1;
}

function rotateMarker(marker, heading) {
  const visual = marker.getElement()?.querySelector('img');
  if (!visual || !Number.isFinite(heading)) return;
  const previous = Number.isFinite(marker._yavoiHeading) ? marker._yavoiHeading : heading;
  const turn = ((heading - previous + 540) % 360) - 180;
  marker._yavoiHeading = previous + turn;
  visual.style.transform = `rotate(${marker._yavoiHeading}deg)`;
}

function animateMarker(marker, points, {
  duration = 9000,
  loop = false,
  loopPause = 1700,
  progressCallback = null,
  completeCallback = null,
  traceLine = null
} = {}) {
  if (!marker || !points || points.length < 2) return;
  stopMarker(marker);
  const token = marker._yavoiAnimation;
  const measurements = routeMeasurements(points);
  let startTime = null;

  function frame(timestamp) {
    if (marker._yavoiAnimation !== token) return;
    if (!startTime) startTime = timestamp;
    const elapsed = timestamp - startTime;
    const cycleDuration = duration + loopPause;
    const cycleTime = loop ? elapsed % cycleDuration : Math.min(elapsed, duration);
    const normalized = Math.min(cycleTime / duration, 1);
    const position = routePosition(points, measurements, normalized);
    const resetting = loop && cycleTime > duration + loopPause * .58;
    marker.setOpacity(resetting ? 0 : 1);
    if (!resetting) {
      marker.setLatLng(position.point);
      rotateMarker(marker, position.heading);
      traceLine?.setLatLngs(travelledPoints(points, position));
    }
    if (typeof progressCallback === 'function') progressCallback(normalized);
    if (!loop && elapsed >= duration) {
      if (typeof completeCallback === 'function') completeCallback();
      return;
    }
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
}

async function setupLoopMap(id, start, end, duration, progressCallback = null) {
  const map = baseMap(id, 14, false);
  if (!map) return { map:null, marker:null };
  const points = await roadRoute(start, end);
  drawRoute(map, points);
  addEndpoints(map, points);
  map.fitBounds(points, { padding:[36,36] });
  const marker = L.marker(points[0], { icon:carIcon(), zIndexOffset:1000 }).addTo(map);
  const traceLine = drawTravelledRoute(map, points[0]);
  animateMarker(marker, points, { duration, loop:true, progressCallback, traceLine });
  return { map, marker };
}

let heroMap, previewMap, securityMap, riderMap, driverMap;
let heroCar, previewCar, securityCar, riderCar, driverCar;
let riderRouteLine, riderEndpointLayers = [];
let driverRouteLine, driverEndpointLayers = [];
let riderTraceLine, driverTraceLine;
let riderRoadPoints = [], riderApproachPoints = [];
let driverApproachPoints = [], driverTripRoadPoints = [];
let riderRouteVersion = 0;

async function initializeMaps() {
  if (typeof L === 'undefined') {
    showToast('Los mapas requieren conexión a internet para mostrar OpenStreetMap.');
    return;
  }
  const heroStart = locations.centro.point;
  const heroEnd = locations.tec.point;
  riderMap = baseMap('riderMap', 14, true);
  driverMap = baseMap('driverMap', 14, true);
  const [heroResult, previewResult, securityResult] = await Promise.all([
    setupLoopMap('heroMap', heroStart, heroEnd, 18000, progress => {
    const eta = $('#heroEta');
    if (eta) eta.textContent = `${Math.max(3, Math.round(9 - progress * 6))} min`;
    }),
    setupLoopMap('previewMap', DEMO_DRIVER_START, heroStart, 15000, progress => {
    const eta = $('#previewEta');
    const distance = $('#previewDistance');
    if (eta) eta.textContent = `Llega en ${Math.max(2, Math.round(5 - progress * 3))} min`;
    if (distance) distance.textContent = `${Math.max(.3, 1.4 - progress).toFixed(1)} km`;
    }),
    setupLoopMap('securityMap', heroStart, heroEnd, 17000),
    prepareRiderRoute(),
    prepareDriverRoute()
  ]);
  ({ map:heroMap, marker:heroCar } = heroResult);
  ({ map:previewMap, marker:previewCar } = previewResult);
  ({ map:securityMap, marker:securityCar } = securityResult);
}

initializeMaps().catch(() => showToast('No pudimos iniciar una de las rutas demostrativas. Intenta recargar la página.'));

function currentRiderSelection() {
  const originKey = $('#riderOrigin')?.value || 'centro';
  const destinationKey = $('#riderDestination')?.value || 'tec';
  const origin = locations[originKey] || locations.centro;
  const destination = locations[destinationKey] || locations.tec;
  return { origin, destination };
}

function clearRouteLayers(map, line, endpoints) {
  if (map && line) map.removeLayer(line);
  endpoints.forEach(layer => map?.removeLayer(layer));
}

async function prepareRiderRoute() {
  if (!riderMap) return;
  const version = ++riderRouteVersion;
  const { origin, destination } = currentRiderSelection();
  const [points, approach] = await Promise.all([
    roadRoute(origin.point, destination.point),
    roadRoute(DEMO_DRIVER_START, origin.point)
  ]);
  if (version !== riderRouteVersion) return;
  riderRoadPoints = points;
  riderApproachPoints = approach;
  clearRouteLayers(riderMap, riderRouteLine, riderEndpointLayers);
  if (riderCar) riderMap.removeLayer(riderCar);
  if (riderTraceLine) riderMap.removeLayer(riderTraceLine);
  riderRouteLine = drawRoute(riderMap, points);
  riderEndpointLayers = addEndpoints(riderMap, points);
  fitRouteForPhone(riderMap, [...approach, ...points]);
  riderCar = L.marker(approach[0], { icon:carIcon(), zIndexOffset:1000, opacity:0 }).addTo(riderMap);
  riderTraceLine = drawTravelledRoute(riderMap, points[0]);
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

$('#riderOrigin')?.addEventListener('change', async () => { resetRider(false); await prepareRiderRoute(); });
$('#riderDestination')?.addEventListener('change', async () => { resetRider(false); await prepareRiderRoute(); updateRiderEstimate(); });

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

$('#riderAction')?.addEventListener('click', async () => {
  if (riderBusy) return;
  const { destination } = currentRiderSelection();
  if (!riderRoadPoints.length || !riderApproachPoints.length) await prepareRiderRoute();
  const points = riderRoadPoints;
  const approach = riderApproachPoints;

  if (riderPhase === 0) {
    riderBusy = true;
    setRiderUI({ state:'Buscando', kicker:'CONECTANDO', title:'Buscando un conductor cercano', action:'Buscando conductor', disabled:true });
    fitRouteForPhone(riderMap, approach);
    riderCar.setLatLng(approach[0]).setOpacity(1);
    setTimeout(() => {
      $('#assignedDriver')?.classList.remove('hidden');
      setRiderUI({ state:'Asignado', kicker:'CONDUCTOR EN CAMINO', title:'Laura llega en pocos minutos', action:'Unidad acercándose', disabled:true });
      riderTraceLine?.setLatLngs([approach[0], approach[0]]);
      animateMarker(riderCar, approach, { duration:3600, traceLine:riderTraceLine, progressCallback:progress => {
        const eta = $('#riderEta');
        if (eta) eta.textContent = `${Math.max(1, Math.round(4 - progress * 3))} min`;
      }, completeCallback:() => {
        riderBusy = false;
        riderPhase = 1;
        setRiderUI({ state:'Llegó', kicker:'UNIDAD EN EL PUNTO', title:'Tu Yavoi! ya llegó', action:'Iniciar viaje' });
      }});
    }, 900);
    return;
  }

  if (riderPhase === 1) {
    riderBusy = true;
    setRiderUI({ state:'En viaje', kicker:'VIAJE EN CURSO', title:`Rumbo a ${destination.label}`, action:'Ruta monitoreada', disabled:true });
    fitRouteForPhone(riderMap, points);
    riderTraceLine?.setLatLngs([points[0], points[0]]);
    animateMarker(riderCar, points, { duration:destination.label.includes('Meoqui') ? 7800 : 5600, traceLine:riderTraceLine, progressCallback:progress => {
      const eta = $('#riderEta');
      if (eta) eta.textContent = `${Math.max(1, Math.round((destination.label.includes('Meoqui') ? 18 : 9) * (1-progress)))} min`;
    }, completeCallback:() => {
      riderBusy = false;
      riderPhase = 2;
      setRiderUI({ state:'Llegaste', kicker:'DESTINO ALCANZADO', title:'Llegaste a tu destino', action:'Finalizar y calificar' });
    }});
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

async function driverTripPoints() {
  const pickup = [28.19065,-105.47045];
  const destination = [28.19015,-105.45785];
  const [approach, trip] = await Promise.all([
    roadRoute(DEMO_DRIVER_START, pickup),
    roadRoute(pickup, destination)
  ]);
  return {
    approach,
    trip
  };
}

async function prepareDriverRoute() {
  if (!driverMap) return;
  const { approach, trip } = await driverTripPoints();
  driverApproachPoints = approach;
  driverTripRoadPoints = trip;
  clearRouteLayers(driverMap, driverRouteLine, driverEndpointLayers);
  if (driverCar) driverMap.removeLayer(driverCar);
  if (driverTraceLine) driverMap.removeLayer(driverTraceLine);
  const full = [...approach, ...trip.slice(1)];
  driverRouteLine = drawRoute(driverMap, full);
  driverEndpointLayers = addEndpoints(driverMap, full);
  fitRouteForPhone(driverMap, full);
  driverCar = L.marker(approach[0], { icon:carIcon(), zIndexOffset:1000 }).addTo(driverMap);
  driverTraceLine = drawTravelledRoute(driverMap, approach[0]);
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

async function resetDriver() {
  driverPhase = 0;
  driverBusy = false;
  await prepareDriverRoute();
  setDriverUI({ status:'Conectado', kicker:'NUEVO SERVICIO', action:'Aceptar servicio', help:'Acepta el servicio para activar la navegación hacia el pasajero. Después podrás marcar llegada, iniciar el viaje y finalizarlo.' });
  if ($('#driverPrice')) $('#driverPrice').textContent = '$86';
  startDriverCountdown();
}

$('#resetDriver')?.addEventListener('click', resetDriver);

$('#driverAction')?.addEventListener('click', async () => {
  if (driverBusy) return;
  if (!driverApproachPoints.length || !driverTripRoadPoints.length) await prepareDriverRoute();
  const approach = driverApproachPoints;
  const trip = driverTripRoadPoints;

  if (driverPhase === 0) {
    clearInterval(countdownTimer);
    driverBusy = true;
    setDriverUI({ status:'En ruta', kicker:'SERVICIO ACEPTADO', action:'Navegando al pasajero', disabled:true, help:'La unidad se dirige al punto de recogida. El pasajero puede seguir el avance en su mapa.' });
    fitRouteForPhone(driverMap, approach);
    driverTraceLine?.setLatLngs([approach[0], approach[0]]);
    animateMarker(driverCar, approach, { duration:4200, traceLine:driverTraceLine, completeCallback:() => {
      driverBusy = false;
      driverPhase = 1;
      setDriverUI({ status:'En punto', kicker:'PUNTO DE RECOGIDA', action:'Marcar llegada', help:'Llegaste al origen. Marca la llegada para avisar al pasajero y habilitar el inicio del viaje.' });
    }});
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
    fitRouteForPhone(driverMap, trip);
    driverTraceLine?.setLatLngs([trip[0], trip[0]]);
    animateMarker(driverCar, trip, { duration:5200, traceLine:driverTraceLine, completeCallback:() => {
      driverBusy = false;
      driverPhase = 3;
      setDriverUI({ status:'Destino', kicker:'DESTINO ALCANZADO', action:'Finalizar servicio', help:'Llegaste al destino. Finaliza para registrar el servicio y actualizar ganancias.' });
    }});
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

if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
  window.addEventListener('load', () => navigator.serviceWorker.register('/sw.js').catch(() => {}));
}

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
      .hero-wordmark-runtime { display:block; width:min(95%,720px) !important; height:auto !important; max-width:95% !important; object-fit:contain; object-position:left center; margin:.10em 0 0; }
      .final-card > img { width:min(390px,72vw) !important; height:auto !important; max-height:none !important; margin-inline:auto; }
      .footer-brand img { width:245px !important; height:auto !important; max-height:none !important; }
      @media (max-width: 1100px) {
        .brand { min-width: 205px; }
        .brand img { width:195px !important; height:74px !important; }
        .app-brand-row img { width:150px !important; height:58px !important; }
        .hero-wordmark-runtime { width:94% !important; max-width:94% !important; }
      }
      @media (max-width: 760px) {
        .nav-shell { min-height: 92px; }
        .brand { min-width: 0; }
        .brand img { width:178px !important; height:68px !important; }
        .hero-wordmark-runtime { width:92% !important; max-width:92% !important; height:auto !important; }
        .app-brand-row img { width:142px !important; height:56px !important; }
        .footer-brand img { width:210px !important; }
      }
      @media (max-width: 430px) {
        .brand img { width:158px !important; height:62px !important; }
        .hero-wordmark-runtime { width:94% !important; max-width:94% !important; height:auto !important; }
      }
    `;
    document.head.appendChild(style);
  }
}

enhanceYavoiBranding();
