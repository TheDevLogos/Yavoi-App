import "./portal.css";
import L from "leaflet";
import { createIcons, icons } from "lucide";
import { db, rpc } from "./client.js";
import {
  roles,
  statuses,
  navs,
  places,
  active,
  cents,
  changeDue,
  allowedView,
  escapeHtml as e,
  money,
  errorMessage,
} from "./domain.js";
const $ = (s, el = document) => el.querySelector(s),
  $$ = (s, el = document) => [...el.querySelectorAll(s)];
const I = (name) => `<i data-lucide="${name}" aria-hidden="true"></i>`;
const button = (text, action, kind = "", icon = "arrow-right") =>
  `<button class="btn ${kind}" data-action="${action}">${text}${I(icon)}</button>`;
const S = {
  user: null,
  profile: null,
  driver: null,
  categories: [],
  data: { trips: [], complaints: [], ledger: [], drivers: [], audit: [], points: 0 },
  view: "home",
  trip: null,
  quote: null,
  busy: false,
  map: null,
  markers: [],
  origin: places[0],
  destination: null,
  pick: "destination",
  channel: null,
  watch: null,
  gpsLast: 0,
  factor: null,
  authView: "login",
  authError: "",
  connected: navigator.onLine,
  avatarUrls: {},
  refreshing: false,
  routeVersion: 0,
};
const modal = $("#modal");
let toastTimer, pollTimer;
function iconsNow() {
  createIcons({ icons, attrs: { "stroke-width": 1.8 } });
}
function notify(message) {
  const t = $("#toast");
  t.textContent = message;
  t.classList.add("show");
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.remove("show"), 6500);
}
function closeModal() {
  modal.close();
  modal.innerHTML = "";
}
function openModal(title, content) {
  modal.innerHTML = `<button class="close" type="button" aria-label="Cerrar">${I("x")}</button><h2 id="modal-title">${e(title)}</h2>${content}`;
  $(".close", modal).onclick = closeModal;
  if (!modal.open) modal.showModal();
  iconsNow();
}
modal.addEventListener("click", (ev) => {
  if (ev.target === modal) {
    const r = modal.getBoundingClientRect();
    if (ev.clientX < r.left || ev.clientX > r.right || ev.clientY < r.top || ev.clientY > r.bottom)
      closeModal();
  }
});
function formValues(form) {
  return Object.fromEntries(new FormData(form));
}
function bindForm(id, fn) {
  const form = $(id);
  if (!form) return;
  form.onsubmit = async (ev) => {
    ev.preventDefault();
    if (S.busy) return;
    S.busy = true;
    const submits = $$("button[type=submit],button:not([type])", form);
    submits.forEach((b) => (b.disabled = true));
    $(".form-error", form)?.remove();
    try {
      await fn(formValues(form), form);
    } catch (err) {
      const box = document.createElement("div");
      box.className = "form-error";
      box.setAttribute("role", "alert");
      box.textContent = errorMessage(err);
      form.prepend(box);
    } finally {
      S.busy = false;
      submits.forEach((b) => (b.disabled = false));
    }
  };
}
async function run(fn) {
  if (S.busy) return;
  S.busy = true;
  try {
    await fn();
  } catch (err) {
    notify(errorMessage(err));
  } finally {
    S.busy = false;
  }
}
function date(value) {
  return value
    ? new Date(value).toLocaleString("es-MX", { dateStyle: "medium", timeStyle: "short" })
    : "Ahora";
}
const zoneLabel = (zone) =>
  ({ central: "Centro de Delicias", urban: "Zona urbana", regional: "Zona regional" })[zone] ||
  "Zona por confirmar";
const decimal = (value) => Number(value || 0).toLocaleString("es-MX", { maximumFractionDigits: 2 });
function badge(t) {
  return `<span class="badge ${t.status === "cancelled" ? "cancelled" : ["requested", "scheduled"].includes(t.status) ? "pending" : ""}">${e(statuses[t.status] || t.status)}</span>`;
}
function avatar(name, path, size = "") {
  const url = S.avatarUrls[path];
  return url
    ? `<img class="avatar ${size}" src="${e(url)}" alt="Fotografía de ${e(name)}">`
    : `<div class="avatar ${size}" aria-label="Sin fotografía">${e((name || "YV").slice(0, 2).toUpperCase())}</div>`;
}
async function loadAvatar(path) {
  if (!path || S.avatarUrls[path]) return;
  const { data, error } = await db.storage.from("yavoi-avatars").createSignedUrl(path, 300);
  if (!error) S.avatarUrls[path] = data.signedUrl;
}
function teardownMap() {
  if (S.map) {
    S.map.remove();
    S.map = null;
  }
  S.markers = [];
}
function clearSession() {
  teardownMap();
  if (S.channel) db.removeChannel(S.channel);
  S.channel = null;
  if (S.watch !== null) navigator.geolocation.clearWatch(S.watch);
  S.watch = null;
  S.trip = null;
  S.profile = null;
  S.driver = null;
  S.quote = null;
  S.avatarUrls = {};
  clearInterval(pollTimer);
}
function authPage(view = "login", message = "") {
  clearSession();
  S.authView = view;
  const signup = view === "signup",
    forgot = view === "forgot",
    recovery = view === "recovery";
  const title = signup
    ? "Tu próximo viaje empieza aquí"
    : forgot
      ? "Recupera tu acceso"
      : recovery
        ? "Elige una nueva contraseña"
        : "Bienvenido a Yavoi!";
  $("#app").innerHTML =
    `<div class="auth-layout"><aside class="auth-art"><a href="/"><img class="logo" src="/assets/yavoi-logo.png" alt="Yavoi!"></a><h1>Tu ciudad.<br>Tu camino.<br><span>Tu Yavoi!</span></h1><p>Una sola cuenta para moverte o conducir. Tu espacio, tu información y el control de cada viaje.</p><div class="auth-values"><div>${I("shield-check")} Acceso personal y datos protegidos</div><div>${I("banknote")} Precio claro antes de confirmar</div><div>${I("map-pin")} Hecho para Delicias y su gente</div></div></aside><main class="auth-main"><div class="auth-box"><img class="auth-logo-mobile" src="/assets/yavoi-logo.png" alt="Yavoi!"><a class="top-back" href="/">${I("arrow-left")} Volver a Yavoi!</a><div class="eyebrow">TU RAITE, AL INSTANTE</div><h2>${title}</h2><p>${signup ? "Crea tu acceso. Después de verificar tu correo podrás completar tu perfil de pasajero o conductor." : forgot ? "Te enviaremos un enlace si existe una cuenta con ese correo." : recovery ? "Usa al menos 12 caracteres y una contraseña que no utilices en otro lugar." : "Ingresa con tu correo. Te llevaremos al espacio que corresponde a tu cuenta."}</p>${message ? `<div class="hint" role="status">${e(message)}</div>` : ""}<form id="auth-form">${!recovery ? '<label>Correo electrónico<input name="email" type="email" autocomplete="email" required maxlength="254" placeholder="tu@correo.com"></label>' : ""}${!forgot ? `<label>Contraseña<input name="password" type="password" autocomplete="${signup || recovery ? "new-password" : "current-password"}" required minlength="${signup || recovery ? 12 : 1}" maxlength="128" placeholder="${signup || recovery ? "Al menos 12 caracteres" : "Tu contraseña"}"></label>` : ""}${signup ? '<label class="check"><input required type="checkbox" name="consent">Entiendo que mi cuenta es personal y que debo verificar mi correo.</label>' : ""}<button class="btn wide" type="submit">${signup ? "Crear cuenta" : forgot ? "Enviar enlace" : recovery ? "Guardar contraseña" : "Ingresar"}${I("arrow-right")}</button></form><div class="auth-links"><button class="link" id="auth-switch">${signup || forgot || recovery ? "Ya tengo cuenta" : "Crear una cuenta"}</button>${!signup && !forgot && !recovery ? '<button class="link" id="forgot">Olvidé mi contraseña</button>' : ""}</div><p class="auth-note">Tu navegador puede guardar la contraseña en su administrador seguro. Nunca la guardamos en el historial de viajes.</p></div></main></div>`;
  iconsNow();
  $("#auth-switch").onclick = () => authPage(view === "login" ? "signup" : "login");
  $("#forgot")?.addEventListener("click", () => authPage("forgot"));
  bindForm("#auth-form", async (v) => {
    if (signup) {
      const { error } = await db.auth.signUp({
        email: v.email.trim(),
        password: v.password,
        options: { emailRedirectTo: location.origin + "/portal.html" },
      });
      if (error) throw error;
      authPage(
        "login",
        "Revisa tu correo para confirmar la cuenta. Si ya tienes una, puedes ingresar o recuperar tu contraseña.",
      );
    } else if (forgot) {
      const { error } = await db.auth.resetPasswordForEmail(v.email.trim(), {
        redirectTo: location.origin + "/portal.html#recovery",
      });
      if (error) throw error;
      authPage(
        "login",
        "Si el correo está registrado, recibirás las instrucciones de recuperación.",
      );
    } else if (recovery) {
      const { error } = await db.auth.updateUser({ password: v.password });
      if (error) throw error;
      history.replaceState(null, "", location.pathname);
      await loadSession();
      notify("Contraseña actualizada.");
    } else {
      authLoading = true;
      try {
        const { error } = await db.auth.signInWithPassword({
          email: v.email.trim(),
          password: v.password,
        });
        if (error) throw error;
        await loadSession();
      } finally {
        authLoading = false;
      }
    }
  });
}
function onboarding() {
  const pr = S.profile;
  $("#app").innerHTML =
    `<div class="auth-main"><div class="auth-box"><img class="auth-logo-mobile" style="display:block" src="/assets/yavoi-logo.png" alt="Yavoi!"><div class="eyebrow">UN ÚLTIMO PASO</div><h2>Haz tuyo tu perfil</h2><p>Selecciona cómo usarás esta cuenta. Los conductores deben completar una revisión antes de recibir viajes.</p><form id="onboard"><div class="role-choice"><label><input type="radio" name="role" value="passenger" checked>Pasajero</label><label><input type="radio" name="role" value="driver">Conductor</label></div><label>Nombre completo<input name="name" autocomplete="name" required minlength="2" maxlength="100" value="${e(pr.full_name)}"></label><label>Teléfono de contacto<input name="phone" type="tel" autocomplete="tel" required minlength="10" maxlength="25" value="${e(pr.phone)}"></label><button type="submit" class="btn wide">Guardar mi perfil ${I("arrow-right")}</button></form><button class="link" id="logout">Cerrar sesión</button></div></div>`;
  iconsNow();
  $("#logout").onclick = signOut;
  bindForm("#onboard", async (v) => {
    await rpc("onboard", v);
    await loadSession();
  });
}
async function mfaGate() {
  const { data, error } = await db.auth.mfa.listFactors();
  if (error) throw error;
  let factor = data.totp.find((f) => f.status === "verified");
  const verified = !!factor;
  let qr = "";
  if (!factor) {
    factor = data.totp.find((f) => f.status === "unverified");
    if (factor) {
      await db.auth.mfa.unenroll({ factorId: factor.id });
    }
    const enrolled = await db.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Yavoi Operaciones",
    });
    if (enrolled.error) throw enrolled.error;
    factor = enrolled.data;
    qr = enrolled.data.totp.qr_code;
  }
  S.factor = factor;
  $("#app").innerHTML =
    `<main class="auth-main"><div class="auth-box"><div class="eyebrow">ACCESO A OPERACIONES</div><h2>Verificación en dos pasos</h2><p>${verified ? "Introduce el código de tu aplicación autenticadora." : "Escanea este código con tu aplicación autenticadora y confirma el código de seis dígitos."}</p>${qr ? `<img class="auth-qr" alt="Código QR para configurar autenticación" src="data:image/svg+xml;charset=utf-8,${encodeURIComponent(qr)}">` : ""}<form id="mfa"><label>Código de verificación<input name="code" autocomplete="one-time-code" inputmode="numeric" pattern="[0-9]{6}" maxlength="6" required></label><button type="submit" class="btn wide">Verificar acceso</button></form><button class="link" id="logout">Cerrar sesión</button></div></main>`;
  $("#logout").onclick = signOut;
  bindForm("#mfa", async (v) => {
    const { error } = await db.auth.mfa.challengeAndVerify({ factorId: S.factor.id, code: v.code });
    if (error) throw error;
    await loadSession();
  });
}
async function loadSession() {
  const {
    data: { user },
    error,
  } = await db.auth.getUser();
  if (error || !user) {
    S.user = null;
    return authPage("login");
  }
  S.user = user;
  const b = await rpc("bootstrap");
  S.profile = b.profile;
  S.driver = b.driver;
  S.categories = b.categories || [];
  if (!S.profile.onboarding_complete) return onboarding();
  if (S.profile.role === "admin") {
    const { data, error } = await db.auth.mfa.getAuthenticatorAssuranceLevel();
    if (error) throw error;
    if (data.currentLevel !== "aal2") return mfaGate();
  }
  await loadAvatar(S.profile.avatar_path);
  S.data = await rpc("dashboard");
  await renderRoute();
  startUpdates();
}
async function signOut() {
  await run(async () => {
    const { error } = await db.auth.signOut();
    if (error) throw error;
    clearSession();
    S.user = null;
    history.replaceState(null, "", location.pathname);
    authPage();
  });
}
function shell(content, title, subtitle = "") {
  teardownMap();
  const p = S.profile;
  $("#app").innerHTML =
    `<div class="app-shell"><aside class="sidebar"><a href="/"><img class="logo" src="/assets/yavoi-logo.png" alt="Yavoi!"></a><div class="city">${I("map-pin")} Delicias, Chihuahua</div><div class="nav-label">${e(roles[p.role]).toUpperCase()}</div><nav>${navs[p.role].map(([id, icon, label]) => `<a href="#${id}" class="${S.view === id ? "active" : ""}">${I(icon)}<span>${label}</span></a>`).join("")}</nav><div class="sidebar-bottom"><a class="sidebar-user" href="#profile">${avatar(p.full_name, p.avatar_path)}<div><strong>${e(p.full_name)}</strong><small>${e(roles[p.role])}</small></div></a><button class="logout" data-action="logout">${I("log-out")}<span>Cerrar sesión</span></button></div></aside><div class="workspace"><header class="topbar"><strong>Mi Yavoi! <span class="muted">/ ${e(roles[p.role])}</span></strong><div class="right"><span class="connection ${S.connected ? "" : "offline"}"><i></i>${S.connected ? "Conectado" : "Sin conexión"}</span><a class="landing-link link" href="/">Ir a la landing</a><a class="icon-btn" href="#help" aria-label="Ayuda">${I("headset")}</a><a class="icon-btn" href="#profile" aria-label="Mi perfil">${I("user-round")}</a></div></header><main><div class="page-title"><div><div class="eyebrow">${p.role === "admin" ? "CENTRO DE OPERACIÓN" : "TU CIUDAD. A TU RITMO."}</div><h1>${title}</h1><p>${subtitle}</p></div><span class="badge neutral">${I("shield-check")} Acceso personal</span></div><div id="page-content">${content}</div></main><div class="footer-note">Yavoi! · Tu raite, al instante · Delicias, Chihuahua</div></div></div>`;
  iconsNow();
  $$("[data-action]").forEach((b) => (b.onclick = () => handleAction(b.dataset.action, b)));
}
function mapFrame(
  id = "ride-map",
  caption = "Selecciona puntos en el mapa. La tarifa usa distancia geográfica, no una ruta vial.",
) {
  return `<section class="map-panel"><div class="map-top">Delicias, Chihuahua</div><div class="map" id="${id}" aria-label="Mapa de Delicias"></div><div class="map-caption">${I("shield-check")}<span>${caption}</span></div></section>`;
}
function startMap(trip = null) {
  if (!$("#ride-map")) return;
  S.map = L.map("ride-map", { zoomControl: true, scrollWheelZoom: false }).setView(
    [28.19065, -105.47045],
    14,
  );
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(S.map);
  S.map.zoomControl.setPosition("bottomright");
  if (!trip)
    S.map.on("click", (ev) => {
      const point = {
        name: `Punto en mapa (${ev.latlng.lat.toFixed(5)}, ${ev.latlng.lng.toFixed(5)})`,
        lat: ev.latlng.lat,
        lng: ev.latlng.lng,
      };
      S[S.pick] = point;
      const input = $(`[name=${S.pick === "origin" ? "origin" : "destination"}]`);
      if (input) input.value = point.name;
      drawPoints();
    });
  drawPoints(trip);
  setTimeout(() => S.map?.invalidateSize(), 70);
}
function drawPoints(t = null) {
  if (!S.map) return;
  S.markers.forEach((m) => m.remove());
  S.markers = [];
  const points = t
    ? [
        { lat: t.origin_lat, lng: t.origin_lng },
        { lat: t.dest_lat, lng: t.dest_lng },
      ]
    : [S.origin, S.destination];
  points.forEach((p, i) => {
    if (p)
      S.markers.push(
        L.circleMarker([p.lat, p.lng], {
          radius: 8,
          color: "white",
          weight: 3,
          fillColor: i ? "#09263e" : "#ff6a0a",
          fillOpacity: 1,
        }).addTo(S.map),
      );
  });
  if (points.every(Boolean)) {
    S.markers.push(
      L.polyline(
        points.map((p) => [p.lat, p.lng]),
        { color: "#183c54", weight: 3, dashArray: "7 9", opacity: 0.55 },
      ).addTo(S.map),
    );
    S.map.fitBounds(
      points.map((p) => [p.lat, p.lng]),
      { padding: [55, 55], maxZoom: 15 },
    );
  }
  if (t && S.trip?.location) {
    const loc = S.trip.location;
    const stale = Date.now() - Date.parse(loc.updated_at) > 60000;
    S.markers.push(
      L.circleMarker([loc.lat, loc.lng], {
        radius: 11,
        color: "white",
        weight: 3,
        fillColor: stale ? "#8693a1" : "#ff6a0a",
        fillOpacity: 1,
      })
        .bindTooltip(stale ? "Última posición; señal desactualizada" : "Posición del conductor")
        .addTo(S.map),
    );
  }
}
function riderHome() {
  const current = S.data.trips.find((t) => active(t) && t.status !== "scheduled");
  if (current) {
    location.hash = "trip/" + current.id;
    return;
  }
  const cats = S.categories.filter((c) => c.active);
  shell(
    `<div class="booking"><section class="panel"><h2>Planea tu viaje</h2><form id="quote-form"><label class="input-point">Punto de partida${I("circle-dot")}<input name="origin" list="places" value="${e(S.origin?.name || "")}" required maxlength="200" autocomplete="off"></label><label class="input-point">Destino${I("map-pin")}<input name="destination" list="places" value="${e(S.destination?.name || "")}" placeholder="¿A dónde quieres ir?" required maxlength="200" autocomplete="off"></label><datalist id="places">${places.map((p) => `<option value="${e(p.name)}">`).join("")}</datalist><div class="origin-tools"><button type="button" id="gps-origin">${I("locate-fixed")} Mi ubicación</button><button type="button" id="map-origin">Marcar origen</button><button type="button" id="map-destination">Marcar destino</button></div><h3>Elige cómo moverte</h3><div class="category-grid">${cats.map((c, i) => `<label class="category-option"><div class="car">${I(c.id === "commercial" ? "package" : c.id === "pickup" ? "truck" : "car")}</div><div><strong>Yavoi! ${e(c.name)}</strong><small>${c.seats} plazas · ${money(c.km_cents)}/km estimado</small></div><span class="rate">Desde ${money(c.base_cents)}</span><input type="radio" name="category" value="${e(c.id)}" ${i ? "" : "checked"} required></label>`).join("")}</div><label class="check women">${I("shield-check")} Prefiero una conductora<input name="women_only" type="checkbox"></label><label class="check"><input name="accessible" type="checkbox">Necesito una unidad con accesibilidad verificada</label><label>Programar (opcional)<input name="scheduled_at" type="datetime-local"></label><button class="btn wide" type="submit">Ver tarifa y método de pago ${I("arrow-right")}</button><p class="hint">El precio se calcula en el servidor y se mantiene durante cinco minutos. Una solicitud no garantiza disponibilidad.</p></form></section>${mapFrame()}</div>`,
    `¿A dónde vamos, ${e(S.profile.full_name.split(" ")[0])}?`,
    "Elige tu destino y revisa el precio antes de confirmar.",
  );
  startMap();
  ["origin", "destination"].forEach((k) =>
    $(`[name=${k}]`).addEventListener("change", (ev) => {
      const p = places.find((p) => p.name === ev.target.value);
      if (p) {
        S[k] = p;
        drawPoints();
      } else if (S[k] && ev.target.value !== S[k].name) {
        S[k] = null;
        notify("Marca esa dirección en el mapa para ubicarla con precisión.");
      }
    }),
  );
  $("#map-origin").onclick = () => {
    S.pick = "origin";
    notify("Toca el mapa para marcar el origen.");
  };
  $("#map-destination").onclick = () => {
    S.pick = "destination";
    notify("Toca el mapa para marcar el destino.");
  };
  $("#gps-origin").onclick = () => {
    if (!navigator.geolocation) return notify("Tu navegador no permite ubicación. Usa el mapa.");
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        S.origin = { name: "Mi ubicación", lat: pos.coords.latitude, lng: pos.coords.longitude };
        $("[name=origin]").value = "Mi ubicación";
        drawPoints();
        S.map.setView([S.origin.lat, S.origin.lng], 16);
      },
      () => notify("No se pudo obtener tu ubicación. Puedes marcarla en el mapa."),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 15000 },
    );
  };
  bindForm("#quote-form", async (v) => {
    if (!S.origin || !S.destination)
      throw Error("Selecciona ambos puntos en el mapa o en las sugerencias.");
    S.quote = await rpc("quote", {
      ...v,
      origin_lat: S.origin.lat,
      origin_lng: S.origin.lng,
      dest_lat: S.destination.lat,
      dest_lng: S.destination.lng,
      women_only: v.women_only === "on",
      accessible: v.accessible === "on",
      scheduled_at: v.scheduled_at ? new Date(v.scheduled_at).toISOString() : null,
    });
    paymentModal();
  });
}
function paymentModal() {
  const q = S.quote;
  const category = S.categories.find((c) => c.id === q.category);
  const pickupBasis =
    q.estimate_source === "nearby_online_unit"
      ? "Unidad disponible cercana"
      : "Referencia operativa de la zona";
  openModal(
    "Tu viaje, con todo claro",
    `<div class="route-line">${I("circle-dot")}${e(q.origin)}</div><div class="route-line destination">${I("map-pin")}${e(q.destination)}</div><div class="estimate-grid"><div><small>Conductor a recogerte</small><strong>${decimal(q.pickup_distance_km)} km · ${q.pickup_eta_minutes} min</strong><span>${pickupBasis}</span></div><div><small>Tu recorrido</small><strong>${decimal(q.distance_km)} km · ${q.trip_eta_minutes} min</strong><span>${zoneLabel(q.service_zone)}</span></div></div><p class="hint">Distancias y tiempos estimados con el modelo operativo de Yavoi!; pueden cambiar por tráfico, cierre de calles y ubicación de la unidad. ${q.scheduled_at ? "Programado: " + date(q.scheduled_at) : ""}</p><div class="fare-breakdown"><div class="receipt-row"><span>Inicio del servicio</span><span>${money(category?.base_cents)}</span></div><div class="receipt-row"><span>Reservación</span><span>${money(q.booking_fee_cents)}</span></div>${q.pickup_surcharge_cents ? `<div class="receipt-row"><span>Recogida lejana · excedente de 3 km</span><span>${money(q.pickup_surcharge_cents)}</span></div>` : ""}${q.zone_surcharge_cents ? `<div class="receipt-row"><span>Ajuste por ${zoneLabel(q.service_zone).toLowerCase()}</span><span>${money(q.zone_surcharge_cents)}</span></div>` : ""}${q.accessibility_surcharge_cents ? `<div class="receipt-row"><span>Unidad con accesibilidad</span><span>${money(q.accessibility_surcharge_cents)}</span></div>` : ""}<div class="receipt-row total"><span>Tarifa estimada</span><strong>${money(q.fare_cents)}</strong></div></div><form id="payment"><h3>¿Cómo quieres pagar?</h3><label class="check"><input type="radio" name="payment_method" value="cash" checked>Efectivo al finalizar el viaje</label><label class="check muted"><input type="radio" disabled>Tarjeta · próximamente</label><p class="hint">Tarjeta se habilitará cuando Yavoi! conecte su proveedor. No solicitamos ni almacenamos números de tarjeta.</p><label class="check"><input id="need-change" type="checkbox">Voy a necesitar cambio</label><label id="tender-label" class="hidden">Pagaré con (MXN)<input name="cash_tender" type="number" step="0.01" min="${q.fare_cents / 100}" max="1000" value="${q.fare_cents / 100}"></label><p id="change-preview" class="hint">Paga el importe exacto al llegar a tu destino.</p><button class="btn wide" type="submit">Confirmar y solicitar ${I("arrow-right")}</button></form>`,
  );
  $("#need-change").onchange = (ev) => {
    $("#tender-label").classList.toggle("hidden", !ev.target.checked);
    if (!ev.target.checked) $("[name=cash_tender]").value = q.fare_cents / 100;
    updateChange();
  };
  function updateChange() {
    try {
      $("#change-preview").textContent =
        "Cambio estimado: " + money(changeDue(q.fare_cents, cents($("[name=cash_tender]").value)));
    } catch {}
  }
  $("[name=cash_tender]").oninput = updateChange;
  const requestKey = crypto.randomUUID();
  bindForm("#payment", async (v) => {
    const t = await rpc("request_trip", {
      quote_id: q.id,
      request_key: requestKey,
      payment_method: "cash",
      cash_tender_cents: $("#need-change").checked ? cents(v.cash_tender) : q.fare_cents,
    });
    closeModal();
    S.quote = null;
    S.data = await rpc("dashboard");
    location.hash = "trip/" + t.id;
  });
}
function stats() {
  const ts = S.data.trips,
    completed = ts.filter((t) => t.status === "completed");
  const gross = completed.reduce((n, t) => n + t.fare_cents, 0);
  const items =
    S.profile.role === "admin"
      ? [
          ["Viajes registrados", ts.length],
          ["En operación", ts.filter(active).length],
          ["Ingresos brutos", money(gross)],
          ["Reportes abiertos", S.data.complaints.filter((c) => c.status !== "resolved").length],
        ]
      : [
          ["Viajes completados", completed.length],
          ["Ingreso neto", money(S.data.ledger.reduce((n, l) => n + l.amount_cents, 0))],
          [
            "Propinas en efectivo",
            money(
              S.data.ledger
                .filter((l) => l.kind === "cash_tip")
                .reduce((n, l) => n + l.amount_cents, 0),
            ),
          ],
          ["Calificación", S.data.rating || "Sin evaluar"],
        ];
  return `<div class="grid4 stats">${items.map(([a, b]) => `<div class="stat"><small>${a}</small><strong>${b}</strong><p>Registros de tu operación</p></div>`).join("")}</div>`;
}
async function driverHome() {
  const t = S.data.trips.find((t) => t.driver_id === S.user.id && active(t));
  if (t) {
    location.hash = "trip/" + t.id;
    return;
  }
  const d = S.driver;
  if (!d?.approved) {
    shell(
      `<section class="panel"><span class="badge pending">Expediente pendiente de aprobación</span><h2 class="section-gap">Tu próximo paso: completa tu perfil</h2><p>Necesitamos tu fotografía, licencia, seguro y datos de la unidad. Operaciones revisará el expediente antes de que puedas recibir viajes.</p>${d?.review_note ? `<p class="hint">${e(d.review_note)}</p>` : ""}<a class="btn" href="#profile">Completar mi expediente ${I("arrow-right")}</a></section>`,
      "Hola, " + e(S.profile.full_name.split(" ")[0]),
      "Tu actividad como conductor comienza con una revisión de seguridad.",
    );
    return;
  }
  const offers = await rpc("offers");
  const availabilityActions = `<div class="driver-actions">${button(d.online ? "Desconectarme" : "Conectarme", "availability", d.online ? "secondary" : "", "power")}${d.online ? button("Actualizar mi zona", "presence", "secondary", "locate-fixed") : ""}</div>`;
  shell(
    `<div class="driver-banner"><div><div class="eyebrow">TU DISPONIBILIDAD</div><h2>${d.online ? "Listo para tu próximo viaje" : "Tú eliges cuándo comenzar"}</h2><p>${d.online ? "Comparte tu zona para ordenar las solicitudes por cercanía." : "Conéctate cuando estés listo para recibir solicitudes."}</p></div>${availabilityActions}</div>${stats()}<section class="panel section-gap"><div class="row between"><h2>Solicitudes disponibles</h2>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div>${offers.length ? offers.map((o) => `<article class="offer"><div class="row between"><span class="badge neutral">${e(S.categories.find((c) => c.id === o.category)?.name)}</span><strong class="earn">${money(o.net_cents)}</strong></div><div class="route-line">${I("circle-dot")}${e(o.origin)}</div><div class="route-line destination">${I("map-pin")}${e(o.destination)}</div><div class="estimate-grid compact"><div><small>Para recoger</small><strong>${o.pickup_from_driver_km == null ? "Actualiza tu zona" : `${decimal(o.pickup_from_driver_km)} km`}</strong></div><div><small>Viaje estimado</small><strong>${decimal(o.distance_km)} km · ${o.trip_eta_minutes} min</strong></div></div><div class="meta-row"><span>${zoneLabel(o.service_zone)}</span><span>Efectivo · tarifa ${money(o.fare_cents)}</span><span>Cambio: ${money(changeDue(o.fare_cents, o.cash_tender_cents))}</span>${o.women_only ? "<span>Conductora verificada</span>" : ""}${o.accessible ? "<span>Accesibilidad requerida</span>" : ""}</div><button class="btn wide" data-accept="${e(o.id)}">Aceptar viaje ${I("arrow-right")}</button></article>`).join("") : `<div class="empty">${I("navigation")}<h3>${d.online ? "Sin solicitudes compatibles por ahora" : "Estás desconectado"}</h3><p>${d.online ? "Actualiza tu zona para recibir primero los viajes más cercanos." : "Conéctate para recibir solicitudes compatibles con tu unidad."}</p></div>`}</section>`,
    "Un buen día para conducir.",
    "Tu tiempo, tus viajes y tus ganancias en un mismo lugar.",
  );
  $$("[data-accept]").forEach(
    (b) =>
      (b.onclick = () =>
        run(async () => {
          const t = await rpc("accept", { trip_id: b.dataset.accept });
          location.hash = "trip/" + t.id;
        })),
  );
}
function tableTrips() {
  return `<div class="table-wrap"><table><thead><tr><th>Folio / fecha</th><th>Recorrido</th><th>Estado</th><th>Pago</th><th>Importe</th><th></th></tr></thead><tbody id="trip-rows">${tripRows(S.data.trips)}</tbody></table></div>${!S.data.trips.length ? `<div class="empty">${I("route")}<h3>Tu historial empieza con el primer viaje</h3><p>Los viajes guardados aparecerán aquí.</p></div>` : ""}`;
}
function tripRows(ts) {
  return ts
    .map(
      (t) =>
        `<tr><td><strong>${e(t.id.slice(0, 8).toUpperCase())}</strong><small>${date(t.created_at)}</small></td><td>${e(t.origin)}<small>${e(t.destination)}</small></td><td>${badge(t)}</td><td>Efectivo<small>${t.payment_status === "paid" ? "Recibido" : "Pendiente"}</small></td><td>${money(t.fare_cents)}</td><td><a class="link" href="#trip/${e(t.id)}">Ver viaje</a></td></tr>`,
    )
    .join("");
}
function tripsView() {
  shell(
    `<section class="panel"><div class="row between"><h2>Historial de viajes</h2>${button("Exportar", "export", "secondary", "download")}</div><div class="filter-row"><input id="search-trips" aria-label="Buscar viajes" placeholder="Buscar destino o folio"><select id="filter-status" aria-label="Filtrar estado"><option value="">Todos los estados</option>${Object.entries(
      statuses,
    )
      .map(([id, s]) => `<option value="${id}">${s}</option>`)
      .join("")}</select></div>${tableTrips()}</section>`,
    "Cada viaje, en un solo lugar.",
    "Consulta el recorrido, el pago y el detalle de tus viajes.",
  );
  const filter = () => {
    const q = $("#search-trips").value.toLowerCase(),
      status = $("#filter-status").value;
    $("#trip-rows").innerHTML = tripRows(
      S.data.trips.filter(
        (t) =>
          (!status || t.status === status) &&
          [t.origin, t.destination, t.id].join(" ").toLowerCase().includes(q),
      ),
    );
  };
  $("#search-trips").oninput = filter;
  $("#filter-status").onchange = filter;
}
async function tripView(id) {
  S.trip = await rpc("trip", { trip_id: id });
  const { trip: t, driver, passenger, location: loc, pin, my_rating } = S.trip;
  await Promise.all([loadAvatar(driver?.avatar_path), loadAvatar(passenger?.avatar_path)]);
  const rider = S.user.id === t.passenger_id,
    conductor = S.user.id === t.driver_id;
  const person = rider ? driver : passenger;
  const title = statuses[t.status];
  const progress = ["requested", "accepted", "arrived", "in_progress", "completed"].indexOf(
    t.status,
  );
  const action =
    t.status === "accepted" && conductor
      ? button("Ya llegué al punto", "arrive", "wide", "map-pin")
      : t.status === "arrived" && conductor
        ? `<form id="start-trip"><label>PIN del pasajero<input name="pin" inputmode="numeric" autocomplete="off" pattern="[0-9]{4}" minlength="4" maxlength="4" required placeholder="4 dígitos"></label><button class="btn wide" type="submit">Iniciar viaje ${I("navigation")}</button></form>`
        : t.status === "in_progress" && conductor
          ? button("Llegamos al destino", "finish", "wide", "flag")
          : "";
  let geo = "Sin señal GPS del conductor. No se muestra una ubicación inventada.";
  if (loc)
    geo =
      Date.now() - Date.parse(loc.updated_at) > 60000
        ? "Señal desactualizada. Última posición: " + date(loc.updated_at)
        : "Ubicación recibida: " +
          date(loc.updated_at) +
          ". Precisión: " +
          Math.round(loc.accuracy) +
          " m.";
  shell(
    `<div class="trip-layout"><section class="panel trip-panel">${badge(t)}<h2 class="big-status">${e(title)}</h2><p>${t.status === "requested" ? "Buscamos un conductor disponible que cumpla tus preferencias." : t.status === "scheduled" ? "Tu solicitud se ofrecerá a conductores cerca de la hora programada." : t.status === "accepted" ? "Verifica la unidad y las placas antes de abordar." : t.status === "arrived" ? "Comparte el PIN sólo cuando estés frente al conductor correcto." : t.status === "in_progress" ? "Tu recorrido está registrado y puedes comunicarte con tu conductor." : t.status === "completed" ? "Gracias por viajar con Yavoi! Tu opinión nos ayuda a mejorar." : "La solicitud fue cancelada."}</p><div class="stepper" aria-hidden="true">${[0, 1, 2, 3, 4].map((i) => `<span class="${i <= progress ? "done" : ""}"></span>`).join("")}</div><div class="route-line">${I("circle-dot")}${e(t.origin)}</div><div class="route-line destination">${I("map-pin")}${e(t.destination)}</div>${t.scheduled_at ? `<p class="hint">${I("calendar")} ${date(t.scheduled_at)}</p>` : ""}${person ? `<div class="person-card">${avatar(person.name, person.avatar_path, "big")}<div><small>${rider ? "Tu conductor" : "Tu pasajero"}</small><strong style="display:block;margin-top:5px">${e(person.name)}</strong>${rider ? `<p>${e(driver.vehicle)} · ${e(driver.plate)}</p><small>Calificación: ${driver.rating || "Nuevo conductor"}</small>` : ""}</div></div>` : ""}${pin ? `<div class="pin-card"><span>Tu PIN de inicio<br><small>No lo compartas antes de abordar</small></span><strong>${e(pin)}</strong></div>` : ""}${t.distance_km != null ? `<div class="estimate-grid compact"><div><small>Recogida estimada</small><strong>${decimal(t.pickup_distance_km)} km · ${t.pickup_eta_minutes} min</strong></div><div><small>Recorrido estimado</small><strong>${decimal(t.distance_km)} km · ${t.trip_eta_minutes} min</strong><span>${zoneLabel(t.service_zone)}</span></div></div>` : ""}<div class="receipt-row"><span>Total · efectivo</span><strong>${money(t.fare_cents)}</strong></div><div class="receipt-row"><span>Pago con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row"><span>Cambio</span><strong>${money(changeDue(t.fare_cents, t.cash_tender_cents))}</strong></div>${action}${conductor && active(t) ? `<div class="section-gap">${button(S.watch !== null ? "Detener ubicación" : "Compartir mi ubicación", "gps", "secondary wide", "locate-fixed")}<p class="hint">El GPS web funciona mientras esta página está activa. Mantén el navegador abierto durante el servicio.</p></div>` : ""}${t.status === "completed" && !my_rating && (rider || conductor) ? button(rider ? "Valorar viaje y conductor" : "Valorar pasajero", "rate", "wide", "star") : ""}${my_rating ? `<p class="hint">Evaluación enviada: ${my_rating.stars}/5. Gracias por compartir tu experiencia.</p>` : ""}${t.status === "completed" && conductor ? button("Registrar propina recibida", "tip", "secondary wide section-gap", "heart") : ""}${t.status === "completed" ? button("Ver recibo", "receipt", "secondary wide section-gap", "receipt-text") : ""}${active(t) && t.status !== "in_progress" ? button("Cancelar viaje", "cancel", "danger wide section-gap", "x") : ""}${S.profile.role === "admin" && t.status === "arrived" ? button("Renovar PIN bloqueado", "reset-pin", "secondary wide section-gap", "key-round") : ""}${S.profile.role === "admin" && t.status === "in_progress" ? button("Cancelar por incidencia", "cancel", "danger wide section-gap", "shield-alert") : ""}<div class="row wrap section-gap">${button("Compartir resumen", "share", "secondary", "share-2")}<a href="#help" class="btn secondary">${I("headset")} Ayuda</a></div></section><div class="stack">${mapFrame("ride-map", e(geo))}<section class="panel"><h2>Mensajes del viaje</h2><div id="chat" class="chat">${messagesHtml(S.trip.messages)}</div>${conductor || rider ? `<form id="chat-form" class="chat-form"><input name="body" aria-label="Mensaje" placeholder="Escribe un mensaje…" required maxlength="1000" ${!t.driver_id || !active(t) ? "disabled" : ""}><button class="btn" type="submit" aria-label="Enviar mensaje" ${!t.driver_id || !active(t) ? "disabled" : ""}>${I("send")}</button></form>` : ""}<p class="hint">Para una emergencia real, llama al <a href="tel:911" class="link">911</a>. El chat no es un servicio de atención inmediata.</p></section></div></div>`,
    "Tu viaje Yavoi!",
    "Folio " + e(t.id.slice(0, 8).toUpperCase()) + " · " + date(t.created_at),
  );
  startMap(t);
  bindForm("#start-trip", async (v) => {
    await rpc("transition", { trip_id: t.id, status: "in_progress", pin: v.pin });
    await tripView(t.id);
  });
  bindForm("#chat-form", async (v, f) => {
    await rpc("message", { trip_id: t.id, body: v.body });
    f.reset();
    await refreshTrip();
  });
  if (!active(t) && S.watch !== null) {
    navigator.geolocation.clearWatch(S.watch);
    S.watch = null;
  }
}
function messagesHtml(ms) {
  return ms.length
    ? ms
        .map(
          (m) =>
            `<div class="bubble ${m.sender_id === S.user.id ? "mine" : ""}">${e(m.body)}<small>${new Date(m.created_at).toLocaleTimeString("es-MX", { hour: "2-digit", minute: "2-digit" })}</small></div>`,
        )
        .join("")
    : '<p class="muted">Aquí comienza la conversación.</p>';
}
async function refreshTrip() {
  if (S.view !== "trip" || !S.trip || modal.open || S.busy) return;
  const next = await rpc("trip", { trip_id: S.trip.trip.id });
  if (
    next.trip.status !== S.trip.trip.status ||
    next.trip.driver_id !== S.trip.trip.driver_id ||
    next.pin !== S.trip.pin
  ) {
    await tripView(next.trip.id);
    return;
  }
  S.trip = next;
  if ($("#chat")) $("#chat").innerHTML = messagesHtml(next.messages);
  drawPoints(next.trip);
  const caption = $(".map-caption span");
  if (caption && next.location) {
    const l = next.location;
    caption.textContent =
      (Date.now() - Date.parse(l.updated_at) > 60000 ? "Señal desactualizada. " : "") +
      "Última posición: " +
      date(l.updated_at) +
      " · precisión " +
      Math.round(l.accuracy) +
      " m.";
  }
}
function wallet() {
  const driver = S.profile.role !== "passenger";
  const completed = S.data.trips.filter((t) => t.status === "completed");
  const total = driver
    ? S.data.ledger.reduce((n, l) => n + l.amount_cents, 0)
    : completed.reduce((n, t) => n + t.fare_cents, 0);
  shell(
    `<div class="balance"><small>${driver ? "INGRESO NETO REGISTRADO" : "TOTAL DE VIAJES COMPLETADOS"}</small><h2>${money(total)}</h2><p>${driver ? "Tarifas cobradas, menos comisión, más propinas recibidas." : "Pagos en efectivo registrados por el conductor al terminar."}</p></div><div class="grid2"><section class="panel"><h2>${driver ? "Tus movimientos" : "Métodos de pago"}</h2>${driver ? (S.data.ledger.length ? S.data.ledger.map((l) => `<div class="receipt-row"><div>${e({ fare: "Tarifa cobrada", commission: "Comisión por pagar", cash_tip: "Propina en efectivo" }[l.kind])}<small style="display:block">${date(l.created_at)}</small></div><strong>${money(l.amount_cents)}</strong></div>`).join("") : "<p>Aún no hay movimientos.</p>") : `<div class="row">${I("banknote")}<strong>Efectivo</strong><span class="badge">Disponible</span></div><p class="hint">Indica si necesitas cambio antes de solicitar. El conductor verá el monto con el que pagarás.</p><div class="row muted">${I("credit-card")}<strong>Tarjeta</strong><span class="badge neutral">Próximamente</span></div><p class="hint">No se guardan datos de tarjeta. Esta opción se activará al conectar un proveedor de pagos.</p>`}</section><section class="panel"><h2>${driver ? "Comisiones y liquidaciones" : "Cada peso, con claridad"}</h2><p>${driver ? "Al cobrar en efectivo recibes la tarifa completa. La comisión registrada representa una cuenta pendiente con Yavoi!, no una transferencia ya realizada." : "La tarifa se muestra antes de confirmar. La propina es voluntaria y puedes entregarla directamente en efectivo."}</p><p class="hint">No hay retiros bancarios, cobros automáticos ni devoluciones electrónicas habilitados. Operaciones deberá conciliar el efectivo.</p><a class="btn secondary" href="#trips">Consultar mis viajes ${I("arrow-right")}</a></section></div>`,
    driver ? "Tus ingresos, siempre claros." : "Tu cartera Yavoi!",
    "Consulta los importes registrados en tus viajes.",
  );
}
function rewards() {
  shell(
    `<div class="rewards">${I("gift")}<div><div class="eyebrow">YAVOI! TE RECOMPENSA</div><h2>Cada buen viaje cuenta.</h2><p>Los viajes completados suman 10 puntos.</p></div><div class="points">${S.data.points}<small>PUNTOS ACUMULADOS</small></div></div><div class="grid2"><section class="panel"><h2>Un registro transparente</h2><p>Los puntos se asignan una sola vez por viaje, incluso si se repite la confirmación.</p><div class="hint">El catálogo de canjes aún no está activo. Tus puntos registrados permanecerán en tu cuenta.</div></section><section class="panel"><h2>${S.profile.role === "driver" ? "Un servicio que se nota" : "Gracias por viajar con nosotros"}</h2><p>${S.profile.role === "driver" ? "Tus evaluaciones reflejan la experiencia de los pasajeros. La calificación no se modifica desde tu perfil." : "Después de cada viaje puedes evaluar el trato, la comodidad y la seguridad."}</p><a class="btn secondary" href="#trips">Ver mis viajes ${I("arrow-right")}</a></section></div>`,
    "Tus viajes suman.",
    "Consulta tus puntos y la experiencia que estás construyendo.",
  );
}
async function upload(file, bucket) {
  if (!file || !file.size) return null;
  const types =
    bucket === "yavoi-documents"
      ? ["application/pdf", "image/jpeg", "image/png"]
      : ["image/jpeg", "image/png", "image/webp"];
  if (!types.includes(file.type)) throw Error("Elige un archivo del formato permitido.");
  if (file.size > (bucket === "yavoi-documents" ? 5 : 2) * 1024 * 1024)
    throw Error("El archivo excede el tamaño permitido.");
  const ext = {
    "application/pdf": "pdf",
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
  }[file.type];
  const path = S.user.id + "/" + crypto.randomUUID() + "." + ext;
  const { error } = await db.storage
    .from(bucket)
    .upload(path, file, { upsert: false, contentType: file.type });
  if (error) throw error;
  return path;
}
function profile() {
  const p = S.profile,
    d = S.driver;
  const driver = p.role === "driver";
  shell(
    `<section class="panel"><div class="profile-head">${avatar(p.full_name, p.avatar_path, "big")}<div><h2>${e(p.full_name)}</h2><p>${e(S.user.email)} · ${e(roles[p.role])}</p><small>El tipo de cuenta se protege en el servidor.</small></div></div><form id="profile-form"><div class="grid2"><label>Nombre completo<input name="name" autocomplete="name" required minlength="2" maxlength="100" value="${e(p.full_name)}"></label><label>Teléfono de contacto<input name="phone" type="tel" autocomplete="tel" required minlength="10" maxlength="25" value="${e(p.phone)}"></label><label>Contacto de emergencia<input name="emergency_name" maxlength="100" value="${e(p.emergency_name)}"></label><label>Teléfono de emergencia<input name="emergency_phone" type="tel" maxlength="25" value="${e(p.emergency_phone)}"></label></div><label>Fotografía de perfil · JPG, PNG o WebP, hasta 2 MB<input name="avatar" type="file" accept="image/jpeg,image/png,image/webp"></label><button type="submit" class="btn">Guardar perfil ${I("check")}</button></form></section>${driver ? `<section class="panel section-gap"><div class="row between"><h2>Mi unidad y documentos</h2><span class="badge ${d?.approved ? "" : "pending"}">${d?.approved ? "Aprobado" : "Revisión pendiente"}</span></div><p class="hint">Cambiar el expediente requiere una nueva aprobación. Los documentos se almacenan de forma privada.</p>${d?.review_note ? `<p class="hint">Revisión: ${e(d.review_note)}</p>` : ""}<form id="vehicle-form"><div class="grid2"><label>Modelo y año<input name="vehicle" required minlength="3" maxlength="100" value="${e(d?.vehicle)}" placeholder="Nissan Versa 2024"></label><label>Placas<input name="plate" required minlength="5" maxlength="20" value="${e(d?.plate)}"></label><label>Categoría<select name="category">${S.categories.map((c) => `<option value="${c.id}" ${d?.category === c.id ? "selected" : ""}>${e(c.name)}</option>`).join("")}</select></label><label>Número de licencia<input name="license_number" required maxlength="50" value="${e(d?.license_number)}"></label><label>Vencimiento de licencia<input name="license_expires" type="date" required value="${e(d?.license_expires)}"></label><label>Vencimiento de seguro<input name="insurance_expires" type="date" required value="${e(d?.insurance_expires)}"></label><label>Licencia · PDF/JPG/PNG hasta 5 MB<input name="license_file" type="file" accept="application/pdf,image/jpeg,image/png" ${d?.license_path ? "" : "required"}><small>${d?.license_path ? "Documento recibido. Puedes reemplazarlo." : "Pendiente de cargar"}</small></label><label>Seguro · PDF/JPG/PNG hasta 5 MB<input name="insurance_file" type="file" accept="application/pdf,image/jpeg,image/png" ${d?.insurance_path ? "" : "required"}><small>${d?.insurance_path ? "Documento recibido. Puedes reemplazarlo." : "Pendiente de cargar"}</small></label></div><label class="check"><input type="checkbox" name="advertising_interest" ${d?.advertising_interest ? "checked" : ""}>Me interesa participar en convenios de publicidad</label><button type="submit" class="btn">Enviar expediente a revisión ${I("shield-check")}</button></form></section>` : ""}<section class="panel section-gap"><h2>Acceso y seguridad</h2><p>Tu sesión es personal. Puedes cambiar tu contraseña o cerrar sesión en todos tus dispositivos.</p><div class="row wrap">${button("Cambiar contraseña", "password", "secondary", "key-round")}${button("Cerrar mis sesiones", "logout", "secondary", "log-out")}</div>${p.role === "admin" ? '<p class="hint">Operaciones exige autenticación en dos pasos. Conserva acceso a tu aplicación autenticadora.</p>' : ""}</section>`,
    "Mi perfil",
    "Tu información, tu unidad y las opciones de tu cuenta.",
  );
  bindForm("#profile-form", async (v, f) => {
    const path = await upload(f.elements.avatar.files[0], "yavoi-avatars");
    await rpc("profile", {
      name: v.name,
      phone: v.phone,
      emergency_name: v.emergency_name,
      emergency_phone: v.emergency_phone,
      ...(path ? { avatar_path: path } : {}),
    });
    await loadSession();
    notify("Perfil actualizado.");
  });
  bindForm("#vehicle-form", async (v, f) => {
    const license = await upload(f.elements.license_file.files[0], "yavoi-documents");
    const insurance = await upload(f.elements.insurance_file.files[0], "yavoi-documents");
    await rpc("driver_profile", {
      ...v,
      license_file: undefined,
      insurance_file: undefined,
      license_path: license,
      insurance_path: insurance,
      advertising_interest: v.advertising_interest === "on",
    });
    await loadSession();
    notify("Expediente enviado a revisión.");
  });
}
function help() {
  const admin = S.profile.role === "admin";
  shell(
    `<div class="grid2"><section class="panel">${I("shield-check")}<h2 class="section-gap">Estamos para escucharte</h2><p>Registra un problema de viaje, tarifa, trato u objeto olvidado. Consulta el estado y la respuesta aquí.</p>${button("Registrar un reporte", "complaint", "", "message-square")}</section><section class="panel"><h2>¿Es una emergencia?</h2><p>Si estás en peligro inmediato, llama a los servicios de emergencia. Los reportes escritos no garantizan una respuesta inmediata.</p><a class="btn danger" href="tel:911">${I("phone")} Llamar al 911</a></section></div><section class="panel section-gap"><h2>${admin ? "Bandeja de atención" : "Mis reportes"}</h2>${S.data.complaints.length ? S.data.complaints.map((c) => `<article class="audit-item"><div class="row between"><strong>${e(c.subject)}</strong><span class="badge ${c.status === "resolved" ? "" : "pending"}">${{ open: "Abierto", reviewing: "En revisión", resolved: "Resuelto" }[c.status]}</span></div><p class="section-gap">${e(c.body)}</p>${c.response ? `<p class="hint">Respuesta: ${e(c.response)}</p>` : ""}<small>${date(c.created_at)} · ${e(c.id.slice(0, 8))}</small>${admin ? `<button class="link" data-report="${e(c.id)}">Atender reporte</button>` : ""}</article>`).join("") : '<div class="empty"><p>No tienes reportes registrados.</p></div>'}</section>`,
    "Ayuda y seguridad",
    "Un espacio para resolver dudas y dar seguimiento a cada reporte.",
  );
  $$("[data-report]").forEach(
    (b) =>
      (b.onclick = () => {
        const c = S.data.complaints.find((c) => c.id === b.dataset.report);
        openModal(
          "Atender reporte",
          `<p>${e(c.body)}</p><form id="resolve"><label>Estado<select name="status"><option value="reviewing">En revisión</option><option value="resolved">Resuelto</option><option value="open">Abierto</option></select></label><label>Respuesta<textarea name="response" required minlength="5" maxlength="2000">${e(c.response)}</textarea></label><button class="btn wide" type="submit">Guardar respuesta</button></form>`,
        );
        bindForm("#resolve", async (v) => {
          await rpc("resolve_complaint", { id: c.id, ...v });
          closeModal();
          await refreshPage();
        });
      }),
  );
}
function adminHome() {
  shell(
    `${stats()}<section class="panel section-gap"><div class="row between"><h2>Operación reciente</h2>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div>${tableTrips()}</section><div class="grid2"><section class="panel"><h2>Conductores y unidades</h2><p>${S.data.drivers.filter((d) => d.approved).length} aprobados · ${S.data.drivers.filter((d) => !d.approved).length} por revisar</p><a class="btn secondary" href="#fleet">Revisar expedientes ${I("arrow-right")}</a></section><section class="panel"><h2>Control de la operación</h2><p>Las tarifas y autorizaciones se registran en auditoría. Las comisiones en efectivo requieren conciliación fuera del sistema hasta conectar pagos.</p><a class="btn secondary" href="#audit">Consultar auditoría ${I("arrow-right")}</a></section></div>`,
    "Tu ciudad, en movimiento.",
    "Viajes, unidades, ingresos y atención en un mismo centro de operación.",
  );
}
function fleet() {
  shell(
    `<section class="panel"><h2>Expedientes de conductores</h2>${S.data.drivers.length ? S.data.drivers.map((d) => `<article class="offer"><div class="row between"><div><h3>${e(d.full_name)}</h3><p>${e(d.vehicle) || "Unidad pendiente"} · ${e(d.plate) || "Sin placas"}</p></div><span class="badge ${d.approved ? "" : "pending"}">${d.approved ? "Aprobado" : "Por revisar"}</span></div><div class="meta-row"><span>${e(d.phone)}</span><span>Licencia vence: ${e(d.license_expires || "Sin fecha")}</span><span>Seguro vence: ${e(d.insurance_expires || "Sin fecha")}</span></div><div class="document-row">${d.avatar_path ? `<button class="btn secondary" data-photo="${e(d.avatar_path)}">${I("user-round")} Ver fotografía</button>` : ""}${d.license_path ? `<button class="btn secondary" data-document="${e(d.license_path)}">${I("file-check")} Ver licencia</button>` : ""}${d.insurance_path ? `<button class="btn secondary" data-document="${e(d.insurance_path)}">${I("file-check")} Ver seguro</button>` : ""}<button class="btn" data-review="${e(d.id)}">Revisar autorización ${I("arrow-right")}</button></div>${d.advertising_interest ? "<small>Interesado en convenios de publicidad</small>" : ""}</article>`).join("") : '<div class="empty"><p>Los conductores aparecerán al crear su cuenta y completar el perfil.</p></div>'}</section>`,
    "Conductores y flotilla",
    "Revisa identidad, documentación y capacidades antes de autorizar una unidad.",
  );
  $$("[data-document]").forEach(
    (b) =>
      (b.onclick = () =>
        run(async () => {
          const { data, error } = await db.storage
            .from("yavoi-documents")
            .createSignedUrl(b.dataset.document, 60);
          if (error) throw error;
          openModal(
            "Documento privado",
            `<p>Este enlace vence en un minuto. Revisa el documento antes de aprobar el expediente.</p><a class="btn wide" href="${e(data.signedUrl)}" target="_blank" rel="noopener noreferrer">Abrir documento ${I("external-link")}</a>`,
          );
        })),
  );
  $$("[data-photo]").forEach(
    (b) =>
      (b.onclick = () =>
        run(async () => {
          await loadAvatar(b.dataset.photo);
          openModal(
            "Fotografía del conductor",
            `<img style="display:block;max-width:100%;max-height:60vh;margin:auto" src="${e(S.avatarUrls[b.dataset.photo] || "")}" alt="Fotografía del expediente">`,
          );
        })),
  );
  $$("[data-review]").forEach(
    (b) =>
      (b.onclick = () => {
        const d = S.data.drivers.find((d) => d.id === b.dataset.review);
        openModal(
          "Revisión de " + d.full_name,
          `<form id="review"><label>Resultado<select name="approved"><option value="false">Pendiente / no autorizado</option><option value="true" ${d.approved ? "selected" : ""}>Aprobar conductor</option></select></label><label class="check"><input name="female_verified" type="checkbox" ${d.female_verified ? "checked" : ""}>Identidad de conductora verificada</label><label class="check"><input name="accessible_verified" type="checkbox" ${d.accessible_verified ? "checked" : ""}>Unidad y asistencia de accesibilidad verificadas</label><label>Resultado de la revisión<textarea name="note" required minlength="5" maxlength="1000">${e(d.review_note)}</textarea></label><p class="hint">Confirma documentos, fotografía, vigencias y capacidades. Esta acción queda registrada con tu identidad.</p><button class="btn wide" type="submit">Guardar autorización</button></form>`,
        );
        bindForm("#review", async (v) => {
          await rpc("review_driver", {
            driver_id: d.id,
            approved: v.approved === "true",
            female_verified: v.female_verified === "on",
            accessible_verified: v.accessible_verified === "on",
            note: v.note,
          });
          closeModal();
          await refreshPage();
        });
      }),
  );
}
function rates() {
  shell(
    `<div class="notice-strip">El estimador considera acercamiento de la unidad, recorrido, duración y zona de servicio. Los cambios sólo afectan nuevas cotizaciones y quedan registrados.</div><div class="grid2">${S.categories.map((c) => `<section class="panel"><h2>Yavoi! ${e(c.name)}</h2><form data-category="${c.id}"><label>Tarifa base (MXN)<input name="base" type="number" min="0" max="1000" step="0.01" required value="${c.base_cents / 100}"></label><label>Precio por km estimado (MXN)<input name="km" type="number" min="0" max="100" step="0.01" required value="${c.km_cents / 100}"></label><label>Precio por minuto estimado (MXN)<input name="minute" type="number" min="0" max="100" step="0.01" required value="${c.minute_cents / 100}"></label><label>Tarifa mínima (MXN)<input name="minimum" type="number" min="0" max="1000" step="0.01" required value="${c.minimum_cents / 100}"></label><label>Cuota de reservación (MXN)<input name="booking" type="number" min="0" max="500" step="0.01" required value="${c.booking_fee_cents / 100}"></label><label>Comisión (%)<input name="commission" type="number" min="0" max="50" step="0.01" required value="${c.commission_bps / 100}"></label><label class="check"><input name="active" type="checkbox" ${c.active ? "checked" : ""}>Categoría disponible</label><button class="btn" type="submit">Guardar tarifa</button></form></section>`).join("")}</div>`,
    "Tarifas y categorías",
    "Precios calculados en el servidor, con registro de cada cambio.",
  );
  $$("[data-category]").forEach((f, i) => {
    f.id = "category-" + i;
    bindForm("#" + f.id, async (v) => {
      await rpc("category", {
        id: f.dataset.category,
        base_cents: cents(v.base),
        km_cents: cents(v.km),
        minute_cents: cents(v.minute),
        minimum_cents: cents(v.minimum),
        booking_fee_cents: cents(v.booking),
        commission_bps: cents(v.commission),
        active: v.active === "on",
      });
      await loadSession();
      notify("Tarifa actualizada para nuevas cotizaciones.");
    });
  });
}
function audit() {
  shell(
    `<section class="panel"><h2>Registro de cambios</h2>${S.data.audit.length ? S.data.audit.map((a) => `<div class="audit-item"><strong>${e(a.action)}</strong><small>${date(a.created_at)} · Actor ${e(a.actor_id.slice(0, 8))}</small><p style="font-size:13px;word-break:break-word;margin-top:7px">${e(JSON.stringify(a.detail))}</p></div>`).join("") : '<div class="empty"><p>Aún no hay cambios administrativos registrados.</p></div>'}</section>`,
    "Auditoría de operaciones",
    "Un historial de autorizaciones, tarifas e intervenciones administrativas.",
  );
}
async function updateDriverPresence() {
  if (!navigator.geolocation)
    throw Error(
      "Tu navegador no permite compartir ubicación. Habilítala para ordenar viajes cercanos.",
    );
  const pos = await new Promise((resolve, reject) =>
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: true,
      timeout: 15000,
      maximumAge: 15000,
    }),
  ).catch(() => {
    throw Error(
      "No pudimos obtener tu ubicación. Revisa el permiso del navegador e inténtalo de nuevo.",
    );
  });
  await rpc("presence", {
    lat: pos.coords.latitude,
    lng: pos.coords.longitude,
    accuracy: pos.coords.accuracy,
  });
  notify("Zona actualizada. Las solicitudes se ordenan por cercanía.");
}
async function handleAction(action, b) {
  if (action === "logout") return signOut();
  if (action === "refresh") return run(refreshPage);
  if (action === "availability")
    return run(async () => {
      const goingOnline = !S.driver.online;
      await rpc("availability", { online: goingOnline });
      await loadSession();
      if (goingOnline) await updateDriverPresence();
    });
  if (action === "presence")
    return run(async () => {
      await updateDriverPresence();
      await refreshPage();
    });
  if (action === "export") {
    const header = [
      "Folio",
      "Origen",
      "Destino",
      "Estado",
      "Zona",
      "Km estimados",
      "Minutos estimados",
      "Tarifa MXN",
      "Fecha",
    ];
    const cell = (x) =>
      '"' +
      String(x ?? "")
        .replace(/^[=+@-]/, "'")
        .replaceAll('"', '""') +
      '"';
    const rows = S.data.trips.map((t) => [
      t.id,
      t.origin,
      t.destination,
      statuses[t.status],
      zoneLabel(t.service_zone),
      t.distance_km,
      t.trip_eta_minutes,
      t.fare_cents / 100,
      t.created_at,
    ]);
    const url = URL.createObjectURL(
      new Blob(["\uFEFF" + [header, ...rows].map((r) => r.map(cell).join(",")).join("\r\n")], {
        type: "text/csv;charset=utf-8",
      }),
    );
    const a = document.createElement("a");
    a.href = url;
    a.download = "yavoi-viajes.csv";
    a.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
    return;
  }
  if (action === "password") {
    openModal(
      "Cambiar contraseña",
      `<form id="password"><label>Nueva contraseña<input name="password" type="password" autocomplete="new-password" minlength="12" maxlength="128" required></label><button type="submit" class="btn wide">Actualizar contraseña</button></form>`,
    );
    bindForm("#password", async (v) => {
      const { error } = await db.auth.updateUser({ password: v.password });
      if (error) throw error;
      closeModal();
      notify("Contraseña actualizada.");
    });
    return;
  }
  if (action === "complaint") {
    openModal(
      "Cuéntanos qué ocurrió",
      `<form id="complaint"><label>Viaje (opcional)<select name="trip_id"><option value="">Consulta general</option>${S.data.trips.map((t) => `<option value="${e(t.id)}">${e(t.id.slice(0, 8))} · ${e(t.destination)}</option>`).join("")}</select></label><label>Motivo<select name="subject"><option>Problema con el viaje</option><option>Tarifa o efectivo</option><option>Seguridad</option><option>Objeto olvidado</option><option>Otro</option></select></label><label>Descripción<textarea name="body" required minlength="10" maxlength="2000" placeholder="Cuéntanos lo ocurrido."></textarea></label><button class="btn wide" type="submit">Enviar reporte</button></form>`,
    );
    bindForm("#complaint", async (v) => {
      await rpc("complaint", v);
      closeModal();
      await refreshPage();
      notify("Reporte guardado. Consulta aquí su seguimiento.");
    });
    return;
  }
  const t = S.trip?.trip;
  if (!t) return;
  if (action === "arrive")
    return run(async () => {
      await rpc("transition", { trip_id: t.id, status: "arrived" });
      await tripView(t.id);
    });
  if (action === "finish") {
    openModal(
      "Llegada y pago en efectivo",
      `<p>Confirma con el pasajero que llegaron al destino antes de cerrar el viaje.</p><div class="receipt-row"><span>Tarifa</span><strong>${money(t.fare_cents)}</strong></div><div class="receipt-row"><span>Paga con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row total"><span>Entrega de cambio</span><strong>${money(changeDue(t.fare_cents, t.cash_tender_cents))}</strong></div><form id="finish"><label class="check"><input name="cash_received" type="checkbox" required>Recibí el pago y entregué el cambio correspondiente.</label><button class="btn wide" type="submit">Completar viaje ${I("check")}</button></form>`,
    );
    bindForm("#finish", async () => {
      await rpc("transition", { trip_id: t.id, status: "completed", cash_received: true });
      closeModal();
      await tripView(t.id);
    });
    return;
  }
  if (action === "cancel") {
    openModal(
      "Cancelar viaje",
      `<form id="cancel"><p class="hint">Esta acción cierra la solicitud. No se registra un cargo automático.</p><label>Motivo<textarea name="reason" required minlength="5" maxlength="500"></textarea></label><button class="btn danger wide" type="submit">Confirmar cancelación</button></form>`,
    );
    bindForm("#cancel", async (v) => {
      await rpc("transition", { trip_id: t.id, status: "cancelled", reason: v.reason });
      closeModal();
      await tripView(t.id);
    });
    return;
  }
  if (action === "rate") {
    const rider = S.profile.role === "passenger";
    openModal(
      rider ? "¿Cómo estuvo tu viaje?" : "¿Cómo fue viajar con tu pasajero?",
      `<form id="rating"><p>Tu evaluación se guarda una sola vez por viaje.</p><div class="stars">${[1, 2, 3, 4, 5].map((n) => `<label><input name="stars" type="radio" value="${n}" ${n === 5 ? "checked" : ""} required>${n}${I("star")}</label>`).join("")}</div>${rider ? `<div class="modal-grid"><label>Comodidad<select name="comfort">${[5, 4, 3, 2, 1].map((n) => `<option>${n}</option>`).join("")}</select></label><label>Percepción de seguridad<select name="safety">${[5, 4, 3, 2, 1].map((n) => `<option>${n}</option>`).join("")}</select></label></div>` : ""}<label class="section-gap">Comentario (opcional)<textarea name="comment" maxlength="1000"></textarea></label><button class="btn wide" type="submit">Enviar evaluación</button></form>`,
    );
    bindForm("#rating", async (v) => {
      await rpc("rating", { trip_id: t.id, ...v });
      closeModal();
      await tripView(t.id);
      notify("Gracias. Tu evaluación quedó registrada.");
    });
    return;
  }
  if (action === "tip") {
    openModal(
      "Propina recibida en efectivo",
      `<p>Registra únicamente una propina que ya recibiste. No se cobrará al pasajero por esta acción.</p><form id="tip"><label>Importe (MXN)<input name="amount" type="number" min="1" max="1000" step="0.01" required></label><label class="check"><input required type="checkbox">Confirmo que recibí este importe en efectivo.</label><button class="btn wide" type="submit">Registrar propina</button></form>`,
    );
    bindForm("#tip", async (v) => {
      await rpc("tip", { trip_id: t.id, amount_cents: cents(v.amount) });
      closeModal();
      notify("Propina registrada en tus ingresos.");
    });
    return;
  }
  if (action === "receipt") {
    openModal(
      "Comprobante del viaje",
      `<p>Yavoi! · ${e(t.id.slice(0, 8).toUpperCase())}</p><div class="route-line">${e(t.origin)} → ${e(t.destination)}</div><div class="receipt-row"><span>Finalizó</span><span>${date(t.completed_at)}</span></div><div class="receipt-row"><span>Método</span><strong>Efectivo recibido</strong></div><div class="receipt-row total"><span>Total del viaje</span><strong>${money(t.fare_cents)}</strong></div><p class="hint">Este comprobante de servicio no es una factura fiscal. Las propinas voluntarias se registran por separado.</p>`,
    );
    return;
  }
  if (action === "share") {
    const text = `Mi viaje Yavoi! ${t.id.slice(0, 8).toUpperCase()}: ${t.origin} → ${t.destination}. ${S.trip.driver ? S.trip.driver.name + ", " + S.trip.driver.vehicle + ", placas " + S.trip.driver.plate + "." : ""} Estado: ${statuses[t.status]}. Este resumen no contiene un enlace de GPS en vivo.`;
    return run(async () => {
      if (navigator.share) {
        await navigator.share({ title: "Mi viaje Yavoi!", text });
      } else {
        await navigator.clipboard.writeText(text);
        notify("Resumen copiado. No incluye tu PIN ni datos privados.");
      }
    });
  }
  if (action === "reset-pin") {
    openModal(
      "Renovar PIN de inicio",
      `<p>Se invalidará el PIN anterior y el pasajero recibirá uno nuevo. Usa esta acción después de confirmar su identidad.</p><form id="reset-pin"><label class="check"><input type="checkbox" required>Verifiqué la identidad del pasajero.</label><button class="btn wide" type="submit">Renovar PIN</button></form>`,
    );
    bindForm("#reset-pin", async () => {
      await rpc("reset_pin", { trip_id: t.id });
      closeModal();
      notify("PIN renovado para el pasajero.");
    });
    return;
  }
  if (action === "gps") {
    if (S.watch !== null) {
      navigator.geolocation.clearWatch(S.watch);
      S.watch = null;
      return tripView(t.id);
    }
    if (!navigator.geolocation) return notify("Tu navegador no soporta ubicación.");
    S.watch = navigator.geolocation.watchPosition(
      (pos) => {
        if (Date.now() - S.gpsLast < 5000) return;
        S.gpsLast = Date.now();
        rpc("location", {
          trip_id: t.id,
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          accuracy: pos.coords.accuracy,
        }).catch((err) => notify(errorMessage(err)));
      },
      () => {
        notify("No se pudo obtener ubicación. Revisa los permisos del navegador.");
        if (S.watch !== null) navigator.geolocation.clearWatch(S.watch);
        S.watch = null;
      },
      { enableHighAccuracy: true, timeout: 20000, maximumAge: 5000 },
    );
    await tripView(t.id);
    notify("Ubicación compartida con los participantes del viaje.");
  }
}
async function renderRoute() {
  if (!S.profile) return;
  const hash = location.hash.slice(1).split("/");
  S.view = hash[0] || "home";
  if (!allowedView(S.profile.role, S.view)) {
    S.view = "home";
    history.replaceState(null, "", "#home");
  }
  if (S.view === "trip") {
    if (!/^[0-9a-f-]{36}$/i.test(hash[1] || "")) {
      location.hash = "trips";
      return;
    }
    await tripView(hash[1]);
  } else if (S.view === "home") {
    if (S.profile.role === "passenger") riderHome();
    else if (S.profile.role === "driver") await driverHome();
    else adminHome();
  } else ({ trips: tripsView, profile, wallet, rewards, help, fleet, rates, audit })[S.view]?.();
}
async function refreshPage() {
  const b = await rpc("bootstrap");
  S.profile = b.profile;
  S.driver = b.driver;
  S.categories = b.categories;
  S.data = await rpc("dashboard");
  await renderRoute();
}
function startUpdates() {
  clearInterval(pollTimer);
  if (S.channel) db.removeChannel(S.channel);
  S.channel = db
    .channel("yavoi-account-" + S.user.id)
    .on("postgres_changes", { event: "*", schema: "public", table: "trips" }, () => safeRefresh())
    .on("postgres_changes", { event: "*", schema: "public", table: "locations" }, () =>
      safeRefresh(),
    )
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, () =>
      safeRefresh(),
    )
    .subscribe();
  pollTimer = setInterval(safeRefresh, 15000);
}
async function safeRefresh() {
  if (S.refreshing || S.busy || modal.open || !S.profile || document.hidden) return;
  S.refreshing = true;
  try {
    if (S.view === "trip") await refreshTrip();
    else if (S.view === "home" && S.profile.role !== "passenger") {
      const focused = document.activeElement;
      if (!["INPUT", "TEXTAREA", "SELECT"].includes(focused?.tagName)) await refreshPage();
    }
  } catch (err) {
    if (/Inicia sesión|JWT|token|not authorized/i.test(err.message)) {
      authPage("login", "Tu sesión terminó. Vuelve a ingresar.");
    }
  } finally {
    S.refreshing = false;
  }
}
window.addEventListener("hashchange", () => {
  if (S.profile) run(renderRoute);
});
window.addEventListener("online", () => {
  S.connected = true;
  notify("Conexión recuperada. Actualiza para consultar los últimos datos.");
  safeRefresh();
});
window.addEventListener("offline", () => {
  S.connected = false;
  notify("Sin conexión. Los cambios no se enviarán hasta recuperar la red.");
});
let authLoading = false;
db.auth.onAuthStateChange((event) => {
  if (event === "PASSWORD_RECOVERY") {
    setTimeout(() => authPage("recovery"), 0);
  } else if (event === "SIGNED_OUT") {
    setTimeout(() => {
      S.user = null;
      authPage();
    }, 0);
  } else if (event === "SIGNED_IN" && !S.profile && !authLoading) {
    setTimeout(async () => {
      if (authLoading) return;
      authLoading = true;
      try {
        await loadSession();
      } catch (err) {
        authPage("login", errorMessage(err));
      } finally {
        authLoading = false;
      }
    }, 0);
  }
});
try {
  if (location.hash.includes("recovery")) authPage("recovery");
  else {
    authLoading = true;
    await loadSession();
    authLoading = false;
  }
} catch (err) {
  authLoading = false;
  authPage("login", errorMessage(err));
}
