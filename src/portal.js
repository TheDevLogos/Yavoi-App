import "./portal.css";
import L from "leaflet";
import { createIcons, icons } from "lucide";
import { authProviderSettings, db, rpc } from "./client.js";
import { createGoogleNonce, loadGoogleIdentity, validGoogleClientId } from "./google-auth.js";
import {
  roles,
  statuses,
  navs,
  places,
  active,
  cents,
  changeDue,
  driverDossierStatus,
  passengerProfileStatus,
  profileEditState,
  PASSENGER_POLICY_VERSION,
  allowedView,
  mfaQrSource,
  serviceAsset,
  escapeHtml as e,
  money,
  errorMessage,
} from "./domain.js";
const $ = (s, el = document) => el.querySelector(s),
  $$ = (s, el = document) => [...el.querySelectorAll(s)];
const I = (name) => `<i data-lucide="${name}" aria-hidden="true"></i>`;
const GOOGLE_CLIENT_ID = String(
  import.meta.env.VITE_GOOGLE_CLIENT_ID ||
    "903354099441-4la2ivgqknn9q8kj1ghku6caebc1a4ar.apps.googleusercontent.com",
).trim();
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
  socialProviders: { google: false },
  connected: navigator.onLine,
  avatarUrls: {},
  refreshing: false,
  routeVersion: 0,
  roadRoute: null,
  units: [],
  selectedUnit: null,
  cardEnabled: false,
  mercadoPagoPublicKey: "",
  mpController: null,
  trackingWatch: null,
  heartbeatTimer: null,
  latestPosition: null,
  presenceSending: false,
  presenceSession: crypto.randomUUID(),
  knownOfferIds: new Set(),
  offersInitialized: false,
  draftTimer: null,
};
const modal = $("#modal");
let toastTimer, pollTimer;
const socialIcons = {
  google: `<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#4285f4" d="M21.6 12.2c0-.7-.1-1.4-.2-2H12v3.9h5.4a4.7 4.7 0 0 1-2 3v2.5h3.3c1.9-1.8 2.9-4.4 2.9-7.4Z"/><path fill="#34a853" d="M12 22c2.7 0 5-.9 6.7-2.4l-3.3-2.5c-.9.6-2 1-3.4 1a5.9 5.9 0 0 1-5.5-4.1H3.1v2.6A10 10 0 0 0 12 22Z"/><path fill="#fbbc05" d="M6.5 14a6 6 0 0 1 0-3.9V7.4H3.1A10 10 0 0 0 3.1 16.6L6.5 14Z"/><path fill="#ea4335" d="M12 5.9c1.6 0 3 .5 4.1 1.6l3.1-3.1A10 10 0 0 0 3.1 7.4l3.4 2.7A5.9 5.9 0 0 1 12 5.9Z"/></svg>`,
};
function googleAuthMarkup() {
  if (S.socialProviders.google && validGoogleClientId(GOOGLE_CLIENT_ID)) {
    return '<div id="google-button" class="google-auth-host"><span>Cargando acceso seguro de Google...</span></div>';
  }
  const detail = validGoogleClientId(GOOGLE_CLIENT_ID)
    ? "Pendiente de activación"
    : "Faltan credenciales";
  return `<button type="button" class="google-auth-pending" disabled>${socialIcons.google}<span>Continuar con Google</span><small>${detail}</small></button>`;
}
async function renderOfficialGoogleButton(view) {
  const host = $("#google-button");
  if (!host) return;
  try {
    const [{ raw, hashed }, googleIdentity] = await Promise.all([
      createGoogleNonce(),
      loadGoogleIdentity(),
    ]);
    if (!host.isConnected) return;
    googleIdentity.accounts.id.initialize({
      client_id: GOOGLE_CLIENT_ID,
      nonce: hashed,
      ux_mode: "popup",
      auto_select: false,
      cancel_on_tap_outside: true,
      use_fedcm_for_prompt: true,
      callback: async (response) => {
        if (!response?.credential || S.busy) return;
        S.busy = true;
        authLoading = true;
        try {
          const { error } = await db.auth.signInWithIdToken({
            provider: "google",
            token: response.credential,
            nonce: raw,
          });
          if (error) throw error;
          await loadSession();
        } catch (error) {
          authPage(view, errorMessage(error));
        } finally {
          S.busy = false;
          authLoading = false;
        }
      },
    });
    host.replaceChildren();
    googleIdentity.accounts.id.renderButton(host, {
      type: "standard",
      theme: "outline",
      size: "large",
      text: view === "signup" ? "signup_with" : "signin_with",
      shape: "rectangular",
      logo_alignment: "left",
      locale: "es",
      width: Math.min(400, Math.max(240, Math.floor(host.getBoundingClientRect().width || 400))),
    });
  } catch (error) {
    if (!host.isConnected) return;
    host.replaceChildren();
    const unavailable = document.createElement("button");
    unavailable.type = "button";
    unavailable.disabled = true;
    unavailable.textContent = "Google no está disponible en este momento";
    host.append(unavailable);
    notify(errorMessage(error));
  }
}
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
function serviceNotification(title, body) {
  notify(`${title}. ${body}`);
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  try {
    const item = new Notification(title, {
      body,
      icon: "/icons/yavoi-192.png",
      badge: "/icons/yavoi-maskable-512.png",
      tag: "yavoi-driver-offer",
      renotify: true,
    });
    item.onclick = () => {
      window.focus();
      location.hash = "home";
    };
  } catch {}
}
function announceOffers(offers) {
  const newOffers = offers.filter((offer) => !S.knownOfferIds.has(offer.offer_id));
  offers.forEach((offer) => S.knownOfferIds.add(offer.offer_id));
  if (newOffers.length)
    serviceNotification(
      "Nueva solicitud de viaje",
      `${newOffers[0].passenger_name}, ${newOffers[0].party_size} persona${newOffers[0].party_size === 1 ? "" : "s"}, servicio ${newOffers[0].category}.`,
    );
  S.offersInitialized = true;
}
function closeModal() {
  S.mpController?.unmount?.();
  S.mpController = null;
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
  stopDriverTracking();
  S.trip = null;
  S.profile = null;
  S.driver = null;
  S.quote = null;
  S.roadRoute = null;
  S.units = [];
  S.selectedUnit = null;
  S.avatarUrls = {};
  S.knownOfferIds = new Set();
  S.offersInitialized = false;
  clearTimeout(S.draftTimer);
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
    `<div class="auth-layout"><aside class="auth-art"><a href="/"><img class="logo" src="/assets/yavoi-logo.png" alt="Yavoi!"></a><h1>Tu ciudad.<br>Tu camino.<br><span>Tu Yavoi!</span></h1><p>Una sola cuenta para moverte o conducir. Tu espacio, tu información y el control de cada viaje.</p><div class="auth-values"><div>${I("shield-check")} Acceso personal y datos protegidos</div><div>${I("banknote")} Precio claro antes de confirmar</div><div>${I("map-pin")} Hecho para Delicias y su gente</div></div></aside><main class="auth-main"><div class="auth-box"><img class="auth-logo-mobile" src="/assets/yavoi-logo.png" alt="Yavoi!"><a class="top-back" href="/">${I("arrow-left")} Volver a Yavoi!</a><div class="eyebrow">TU RAITE, AL INSTANTE</div><h2>${title}</h2><p>${signup ? "Crea tu acceso. Después podrás completar tu perfil de pasajero o conductor." : forgot ? "Te enviaremos un enlace si existe una cuenta con ese correo." : recovery ? "Usa al menos 12 caracteres y una contraseña que no utilices en otro lugar." : "Ingresa con tu cuenta. Te llevaremos al espacio que corresponde a tu perfil."}</p>${message ? `<div class="hint" role="status">${e(message)}</div>` : ""}${!forgot && !recovery ? `<div class="social-auth">${googleAuthMarkup()}</div><div class="auth-divider"><span>o usa tu correo</span></div>` : ""}<form id="auth-form">${!recovery ? '<label>Correo electrónico<input name="email" type="email" autocomplete="email" required maxlength="254" placeholder="tu@correo.com"></label>' : ""}${!forgot ? `<label>Contraseña<input name="password" type="password" autocomplete="${signup || recovery ? "new-password" : "current-password"}" required minlength="${signup || recovery ? 12 : 1}" maxlength="128" placeholder="${signup || recovery ? "Al menos 12 caracteres" : "Tu contraseña"}"></label>` : ""}${signup ? '<label class="check"><input required type="checkbox" name="consent">Entiendo que mi cuenta es personal y que debo verificar mi correo.</label>' : ""}<button class="btn wide" type="submit">${signup ? "Crear cuenta" : forgot ? "Enviar enlace" : recovery ? "Guardar contraseña" : "Ingresar"}${I("arrow-right")}</button></form><div class="auth-links"><button class="link" id="auth-switch">${signup || forgot || recovery ? "Ya tengo cuenta" : "Crear una cuenta"}</button>${!signup && !forgot && !recovery ? '<button class="link" id="forgot">Olvidé mi contraseña</button>' : ""}</div><p class="auth-note">Tu navegador puede guardar la contraseña en su administrador seguro. Nunca la guardamos en el historial de viajes.</p></div></main></div>`;
  iconsNow();
  if (!forgot && !recovery && S.socialProviders.google && validGoogleClientId(GOOGLE_CLIENT_ID)) {
    renderOfficialGoogleButton(view);
  }
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
    `<div class="auth-main"><div class="auth-box"><img class="onboarding-logo" src="/assets/yavoi-logo.png" alt="Yavoi!"><div class="eyebrow">UN ÚLTIMO PASO</div><h2>Haz tuyo tu perfil</h2><p>Selecciona cómo usarás esta cuenta. Los conductores deben completar una revisión antes de recibir viajes.</p><form id="onboard"><div class="role-choice"><label><input type="radio" name="role" value="passenger" checked>Pasajero</label><label><input type="radio" name="role" value="driver">Conductor</label></div><label>Nombre completo<input name="name" autocomplete="name" required minlength="2" maxlength="100" value="${e(pr.full_name)}"></label><label>Teléfono de contacto<input name="phone" type="tel" autocomplete="tel" required minlength="10" maxlength="25" value="${e(pr.phone)}"></label><button type="submit" class="btn wide">Guardar mi perfil ${I("arrow-right")}</button></form><button class="link" id="logout">Cerrar sesión</button></div></div>`;
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
  let secret = "";
  if (!factor) {
    factor = data.totp.find((f) => f.status === "unverified");
    if (factor) {
      const removed = await db.auth.mfa.unenroll({ factorId: factor.id });
      if (removed.error) throw removed.error;
    }
    const enrolled = await db.auth.mfa.enroll({
      factorType: "totp",
      friendlyName: "Yavoi Operaciones",
    });
    if (enrolled.error) throw enrolled.error;
    factor = enrolled.data;
    qr = mfaQrSource(enrolled.data.totp.qr_code);
    secret = enrolled.data.totp.secret;
  }
  S.factor = factor;
  $("#app").innerHTML =
    `<main class="auth-main"><div class="auth-box"><div class="eyebrow">ACCESO A OPERACIONES</div><h2>Verificación en dos pasos</h2><p>${verified ? "Introduce el código de tu aplicación autenticadora." : "Escanea el código con Google Authenticator, Microsoft Authenticator, Authy u otra aplicación TOTP."}</p>${qr ? `<figure class="mfa-setup"><img id="mfa-qr" class="auth-qr" alt="Código QR para configurar autenticación" src="${e(qr)}"><figcaption id="qr-error" class="form-error hidden">El navegador no pudo mostrar el QR. Configura la cuenta con la clave manual.</figcaption><div class="mfa-secret"><small>Clave de configuración manual</small><code>${e(secret)}</code><button type="button" class="btn secondary" id="copy-mfa-secret">Copiar clave</button></div></figure>` : ""}<form id="mfa"><label>Código de verificación<input name="code" autocomplete="one-time-code" inputmode="numeric" pattern="[0-9]{6}" minlength="6" maxlength="6" required placeholder="000000"></label><button type="submit" class="btn wide">Verificar acceso</button></form><button class="link" id="logout">Cerrar sesión</button></div></main>`;
  const qrImage = $("#mfa-qr");
  if (qrImage)
    qrImage.onerror = () => {
      qrImage.hidden = true;
      $("#qr-error").classList.remove("hidden");
    };
  $("#copy-mfa-secret")?.addEventListener("click", () =>
    run(async () => {
      await navigator.clipboard.writeText(secret);
      notify("Clave copiada. Agrégala en tu aplicación autenticadora.");
    }),
  );
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
  S.cardEnabled = !!b.card_enabled;
  S.mercadoPagoPublicKey = b.mercado_pago_public_key || "";
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
  if (S.profile.role === "driver" && S.driver?.online) startDriverTracking();
  else stopDriverTracking();
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
    `<div class="app-shell"><aside class="sidebar"><a href="/"><img class="logo" src="/assets/yavoi-logo.png" alt="Yavoi!"></a><div class="city">${I("map-pin")} Delicias, Chihuahua</div><div class="nav-label">${e(roles[p.role]).toUpperCase()}</div><nav>${navs[p.role].map(([id, icon, label]) => `<a href="#${id}" class="${S.view === id ? "active" : ""}">${I(icon)}<span>${label}</span></a>`).join("")}</nav><div class="sidebar-bottom"><a class="sidebar-user" href="#profile">${avatar(p.full_name, p.avatar_path)}<div><strong>${e(p.full_name)}</strong><small>${e(roles[p.role])}</small></div></a><button class="logout" data-action="logout">${I("log-out")}<span>Cerrar sesión</span></button></div></aside><div class="workspace"><header class="topbar"><strong>Mi Yavoi! <span class="muted">/ ${e(roles[p.role])}</span></strong><div class="right"><span class="connection ${S.connected ? "" : "offline"}"><i></i>${S.connected ? "Conectado" : "Sin conexión"}</span><a class="landing-link link" href="/">Ir a la landing</a><a class="icon-btn" href="${p.role === "driver" ? "#home" : "#help"}" aria-label="${p.role === "driver" ? "Ayuda y seguridad en Conducir" : "Ayuda"}">${I("headset")}</a><a class="icon-btn" href="#profile" aria-label="Mi perfil">${I("user-round")}</a></div></header><main><div class="page-title"><div><div class="eyebrow">${p.role === "admin" ? "CENTRO DE OPERACIÓN" : "TU CIUDAD. A TU RITMO."}</div><h1>${title}</h1><p>${subtitle}</p></div><span class="badge neutral">${I("shield-check")} Acceso personal</span></div><div id="page-content">${content}</div></main><div class="footer-note">Yavoi! · Tu raite, al instante · Delicias, Chihuahua</div></div></div>`;
  iconsNow();
  $$("[data-action]").forEach((b) => (b.onclick = () => handleAction(b.dataset.action, b)));
}
function mapFrame(
  id = "ride-map",
  caption = "Busca una dirección o coloca marcadores. Yavoi! trazará la ruta vial disponible.",
) {
  return `<section class="map-panel"><div class="map-top">Delicias, Chihuahua</div><button class="map-fullscreen" type="button" data-action="map-fullscreen" aria-label="Ver mapa en pantalla completa">${I("maximize-2")}<span>Ampliar</span></button><div class="map" id="${id}" aria-label="Mapa de Delicias"></div><div class="map-caption">${I("shield-check")}<span>${caption}</span></div></section>`;
}
async function mapService(body) {
  const { data, error } = await db.functions.invoke("maps", { body });
  if (error) throw new Error(data?.error || error.message);
  if (data?.error) throw new Error(data.error);
  return data;
}
async function searchAddress(kind) {
  const input = $(`[name=${kind}]`);
  const query = input?.value.trim();
  if (!query || query.length < 3) return notify("Escribe al menos tres caracteres para buscar.");
  await run(async () => {
    const result = await mapService({ type: "search", query });
    openModal(
      `Resultados para ${query}`,
      result.results?.length
        ? `<div class="address-results">${result.results.map((place, index) => `<button type="button" data-place="${index}">${I("map-pin")}<span>${e(place.name)}</span></button>`).join("")}</div>`
        : '<div class="empty"><p>No encontramos esa dirección dentro de la cobertura de Delicias y Meoqui.</p></div>',
    );
    $$('[data-place]', modal).forEach((item) => {
      item.onclick = async () => {
        const place = result.results[Number(item.dataset.place)];
        S[kind] = place;
        input.value = place.name;
        closeModal();
        S.roadRoute = null;
        drawPoints();
        await loadRoadRoute();
        if (kind === "origin") await refreshAvailableUnits();
        scheduleRideDraft();
      };
    });
  });
}
async function loadRoadRoute(trip = null) {
  const origin = trip ? { lat: trip.origin_lat, lng: trip.origin_lng } : S.origin;
  const destination = trip ? { lat: trip.dest_lat, lng: trip.dest_lng } : S.destination;
  if (!origin || !destination) return;
  const version = ++S.routeVersion;
  try {
    const route = await mapService({ type: "route", origin, destination });
    if (version !== S.routeVersion) return;
    S.roadRoute = route;
    drawPoints(trip);
  } catch (error) {
    if (version === S.routeVersion) notify("No pudimos trazar la ruta vial; puedes continuar con la estimación operativa.");
  }
}
async function refreshAvailableUnits() {
  if (!S.map || S.profile?.role !== "passenger" || !S.origin) return;
  const category = $('[name=category]:checked')?.value || S.categories.find((c) => c.active)?.id;
  if (!category) return;
  try {
    S.units = await rpc("available_units", {
      lat: S.origin.lat,
      lng: S.origin.lng,
      category,
      women_only: !!$('[name=women_only]')?.checked,
      accessible: !!$('[name=accessible]')?.checked,
    });
    if (S.selectedUnit && !S.units.some((unit) => unit.unit_id === S.selectedUnit)) S.selectedUnit = null;
    const label = $("#unit-status");
    if (label) label.textContent = S.units.length ? `${S.units.length} unidad${S.units.length === 1 ? "" : "es"} disponible${S.units.length === 1 ? "" : "s"}. Puedes elegir una o dejar que Yavoi! asigne la más cercana.` : "No hay unidades compatibles visibles en este momento. Puedes cotizar y esperar disponibilidad.";
    drawPoints();
  } catch (error) {
    notify(errorMessage(error));
  }
}
const pointIcon = (destination = false) => L.icon({
  iconUrl: destination ? "/assets/map-destination.svg" : "/assets/map-origin.svg",
  iconSize: [46, 55],
  iconAnchor: [23, 51],
  tooltipAnchor: [0, -48],
});
const vehicleIcon = (heading = 0, selected = false) => L.divIcon({
  className: "vehicle-icon-wrap",
  html: `<div class="vehicle-icon ${selected ? "selected" : ""}"><img src="/assets/map-car-top.svg" alt="" style="transform:rotate(${Number.isFinite(Number(heading)) ? Number(heading) : 0}deg)"></div>`,
  iconSize: [48, 64],
  iconAnchor: [24, 32],
});
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
      S.roadRoute = null;
      drawPoints();
      loadRoadRoute();
      if (S.pick === "origin") refreshAvailableUnits();
      scheduleRideDraft();
    });
  drawPoints(trip);
  loadRoadRoute(trip);
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
      S.markers.push(L.marker([p.lat, p.lng], { icon: pointIcon(i === 1), zIndexOffset: 1200 })
        .bindTooltip(i ? "Destino" : "Punto de partida", { direction: "top" })
        .addTo(S.map));
  });
  if (points.every(Boolean)) {
    S.markers.push(
      L.polyline(
        S.roadRoute?.coordinates?.length
          ? S.roadRoute.coordinates.map(([lng, lat]) => [lat, lng])
          : points.map((p) => [p.lat, p.lng]),
        { color: "#183c54", weight: 5, opacity: 0.72 },
      ).addTo(S.map),
    );
    S.map.fitBounds(
      points.map((p) => [p.lat, p.lng]),
      { padding: [55, 55], maxZoom: 15 },
    );
  }
  if (!t)
    S.units.forEach((unit, index) => {
      const marker = L.marker([unit.lat, unit.lng], { icon: vehicleIcon(0, S.selectedUnit === unit.unit_id) })
        .bindTooltip(`${index === 0 ? "Recomendada por cercanía" : "Unidad disponible"} · ${decimal(unit.pickup_km)} km · ${unit.pickup_minutes} min`)
        .on("click", () => {
          S.selectedUnit = S.selectedUnit === unit.unit_id ? null : unit.unit_id;
          drawPoints();
          const label = $("#unit-selection");
          if (label) label.textContent = S.selectedUnit
            ? `${index === 0 ? "Unidad más cercana elegida" : "Unidad elegida por ti"} · ${decimal(unit.pickup_km)} km · ${unit.pickup_minutes} min`
            : "Asignación automática a la unidad más cercana";
        })
        .addTo(S.map);
      S.markers.push(marker);
    });
  if (t && S.trip?.route_history?.length > 1) {
    S.markers.push(L.polyline(S.trip.route_history.map((point) => [point.lat, point.lng]), { color: "#ff6a0a", weight: 6, opacity: 0.9 }).addTo(S.map));
  }
  if (t && S.trip?.location) {
    const loc = S.trip.location;
    const stale = Date.now() - Date.parse(loc.updated_at) > 60000;
    S.markers.push(
      L.marker([loc.lat, loc.lng], { icon: vehicleIcon(loc.heading || 0) })
        .bindTooltip(stale ? "Última posición; señal desactualizada" : "Posición del conductor")
        .addTo(S.map),
    );
  }
}
function draftPoint(draft, prefix) {
  const name = draft?.[prefix === "origin" ? "origin" : "destination"];
  const lat = Number(draft?.[prefix === "origin" ? "origin_lat" : "dest_lat"]);
  const lng = Number(draft?.[prefix === "origin" ? "origin_lng" : "dest_lng"]);
  return name && Number.isFinite(lat) && Number.isFinite(lng) ? { name, lat, lng } : null;
}
function rideDraftPayload(form = $("#quote-form")) {
  if (!form) return null;
  const values = Object.fromEntries(new FormData(form));
  const originValid = S.origin && values.origin === S.origin.name;
  const destinationValid = S.destination && values.destination === S.destination.name;
  return {
    origin: values.origin || "",
    origin_lat: originValid ? S.origin.lat : null,
    origin_lng: originValid ? S.origin.lng : null,
    destination: values.destination || "",
    dest_lat: destinationValid ? S.destination.lat : null,
    dest_lng: destinationValid ? S.destination.lng : null,
    category: values.category || "basic",
    party_size: Number(values.party_size || 1),
    service_notes: values.service_notes || "",
    women_only: values.women_only === "on",
    accessible: values.accessible === "on",
    scheduled_at: values.scheduled_at || null,
  };
}
function scheduleRideDraft() {
  clearTimeout(S.draftTimer);
  S.draftTimer = setTimeout(async () => {
    const payload = rideDraftPayload();
    if (!payload || !S.connected || S.profile?.role !== "passenger") return;
    try {
      await rpc("save_ride_draft", payload);
      S.data.ride_draft = payload;
      const state = $("#draft-state");
      if (state) state.textContent = "Plan guardado";
    } catch {}
  }, 700);
}
function riderHome() {
  const current = S.data.trips.find((trip) => active(trip) && trip.status !== "scheduled");
  if (current) {
    location.hash = "trip/" + current.id;
    return;
  }
  const passengerProgress = passengerProfileStatus(S.profile);
  if (passengerProgress.percent < 100) {
    shell(
      `<section class="panel profile-required"><div class="profile-head"><div class="profile-lock">${I("shield-check")}</div><div><div class="eyebrow">SEGURIDAD ANTES DEL PRIMER VIAJE</div><h2>Completa tu perfil de pasajero</h2><p>Necesitamos tus datos de contacto, fotografía, contacto de emergencia y aceptación de las reglas de seguridad.</p></div></div><div class="dossier-progress"><div class="row between"><strong>${passengerProgress.percent}% completo</strong><b>${passengerProgress.completed} de ${passengerProgress.total}</b></div><progress max="100" value="${passengerProgress.percent}">${passengerProgress.percent}%</progress><p>Falta: ${e(passengerProgress.missing.join(", "))}.</p></div><a class="btn" href="#profile">Completar mi perfil ${I("arrow-right")}</a></section>`,
      "Prepara tu cuenta",
      "Completa estos datos una sola vez para solicitar viajes con mayor seguridad.",
    );
    return;
  }
  const draft = S.data.ride_draft;
  if (draft) {
    S.origin = draftPoint(draft, "origin") || S.origin;
    S.destination = draftPoint(draft, "destination");
  }
  const cats = S.categories.filter((category) => category.active);
  const selectedCategory = draft?.category || cats[0]?.id;
  shell(
    `<div class="booking"><section class="panel"><div class="row between"><h2>Planea tu viaje</h2><small id="draft-state">${draft ? "Plan recuperado" : "Guardado automático"}</small></div><form id="quote-form"><div class="address-field"><label class="input-point">Punto de partida${I("circle-dot")}<input name="origin" list="places" value="${e(S.origin?.name || draft?.origin || "")}" required maxlength="200" autocomplete="street-address"></label><button type="button" data-search-address="origin" aria-label="Buscar punto de partida">${I("search")}</button></div><div class="address-field"><label class="input-point">Destino${I("map-pin")}<input name="destination" list="places" value="${e(S.destination?.name || draft?.destination || "")}" placeholder="Calle, número o lugar" required maxlength="200" autocomplete="street-address"></label><button type="button" data-search-address="destination" aria-label="Buscar destino">${I("search")}</button></div><datalist id="places">${places.map((place) => `<option value="${e(place.name)}">`).join("")}</datalist><div class="origin-tools"><button type="button" id="gps-origin">${I("locate-fixed")} Mi ubicación</button><button type="button" id="map-origin"><img src="/assets/map-origin.svg" alt=""> Marcar origen</button><button type="button" id="map-destination"><img src="/assets/map-destination.svg" alt=""> Marcar destino</button></div><h3>Elige cómo moverte</h3><div class="category-grid">${cats.map((category) => `<label class="category-option"><div class="car"><img src="${serviceAsset(category.id)}" alt=""></div><div><strong>Yavoi! ${e(category.name)}</strong><small>${category.seats} plazas · ${money(category.km_cents)}/km estimado</small></div><span class="rate">Desde ${money(category.minimum_cents)}</span><input type="radio" name="category" value="${e(category.id)}" ${category.id === selectedCategory ? "checked" : ""} required></label>`).join("")}</div><div class="grid2 service-request"><label>Personas que viajarán<input name="party_size" type="number" min="1" max="8" step="1" required value="${e(draft?.party_size || 1)}"></label><label>Indicaciones para el conductor<textarea name="service_notes" maxlength="500" placeholder="Ejemplo: requiero espacio para mesas y equipo">${e(draft?.service_notes || "")}</textarea></label></div><label class="check women">${I("shield-check")} Prefiero una conductora<input name="women_only" type="checkbox" ${draft?.women_only ? "checked" : ""}></label><label class="check accessible-service">${I("accessibility")}<span>Servicio para personas con alguna discapacidad</span><input name="accessible" type="checkbox" ${draft?.accessible ? "checked" : ""}></label><div class="unit-summary"><img class="unit-map-car" src="/assets/map-car-top.svg" alt=""> <div><strong id="unit-selection">Asignación automática a la unidad más cercana</strong><small id="unit-status">Consultando unidades disponibles…</small></div></div><label>Programar (opcional)<input name="scheduled_at" type="datetime-local" value="${e(draft?.scheduled_at || "")}"></label><button class="btn wide" type="submit">Ver tarifa y método de pago ${I("arrow-right")}</button><p class="hint">Guardamos este plan en tu cuenta. Si recargas o cierras por accidente, podrás continuar. Yavoi! recomienda la unidad compatible más cercana, pero puedes elegir cualquier unidad visible; el conductor conserva la decisión de aceptar.</p></form></section>${mapFrame()}</div>`,
    `¿A dónde vamos, ${e(S.profile.full_name.split(" ")[0])}?`,
    "Elige tu destino, necesidades y revisa el precio antes de confirmar.",
  );
  startMap();
  refreshAvailableUnits();
  $$('[data-search-address]').forEach((search) => search.onclick = () => searchAddress(search.dataset.searchAddress));
  $$('[name=category],[name=women_only],[name=accessible]').forEach((control) => control.addEventListener("change", () => {
    refreshAvailableUnits();
    scheduleRideDraft();
  }));
  $$('[name=origin],[name=destination],[name=party_size],[name=service_notes],[name=scheduled_at]').forEach((control) => control.addEventListener("input", scheduleRideDraft));
  ["origin", "destination"].forEach((kind) =>
    $(`[name=${kind}]`).addEventListener("change", (event) => {
      const place = places.find((item) => item.name === event.target.value);
      if (place) {
        S[kind] = place;
        S.roadRoute = null;
        drawPoints();
        loadRoadRoute();
        if (kind === "origin") refreshAvailableUnits();
      } else if (S[kind] && event.target.value !== S[kind].name) {
        S[kind] = null;
        notify("Marca esa dirección en el mapa para ubicarla con precisión.");
      }
      scheduleRideDraft();
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
      (position) => {
        S.origin = { name: "Mi ubicación", lat: position.coords.latitude, lng: position.coords.longitude };
        $("[name=origin]").value = "Mi ubicación";
        drawPoints();
        S.map.setView([S.origin.lat, S.origin.lng], 16);
        loadRoadRoute();
        refreshAvailableUnits();
        scheduleRideDraft();
      },
      () => notify("No se pudo obtener tu ubicación. Puedes marcarla en el mapa."),
      { enableHighAccuracy: true, timeout: 15000, maximumAge: 15000 },
    );
  };
  bindForm("#quote-form", async (values) => {
    if (!S.origin || !S.destination)
      throw Error("Selecciona ambos puntos en el mapa o en las sugerencias.");
    S.quote = await rpc("quote", {
      ...values,
      party_size: Number(values.party_size),
      origin_lat: S.origin.lat,
      origin_lng: S.origin.lng,
      dest_lat: S.destination.lat,
      dest_lng: S.destination.lng,
      women_only: values.women_only === "on",
      accessible: values.accessible === "on",
      scheduled_at: values.scheduled_at ? new Date(values.scheduled_at).toISOString() : null,
      preferred_driver_id: S.selectedUnit,
    });
    if (S.roadRoute) {
      S.quote.road_distance_km = S.roadRoute.distance_km;
      S.quote.road_duration_minutes = S.roadRoute.duration_minutes;
    }
    paymentModal();
  });
}
function paymentModal() {
  const q = S.quote;
  const category = S.categories.find((c) => c.id === q.category);
  const pickupBasis =
    q.preferred_driver_id
      ? "Unidad elegida por ti"
      : q.estimate_source === "nearby_online_unit"
      ? "Unidad disponible cercana"
      : "Referencia operativa de la zona";
  const transparentFare =
    Number(category?.base_cents || 0) +
    Number(q.distance_charge_cents || 0) +
    Number(q.time_charge_cents || 0) +
    Number(q.minimum_adjustment_cents || 0) +
    Number(q.pickup_surcharge_cents || 0) +
    Number(q.zone_surcharge_cents || 0) +
    Number(q.accessibility_surcharge_cents || 0);
  if (transparentFare !== Number(q.fare_cents)) {
    S.quote = null;
    notify("La cotización no pasó la validación de suma. Calcula nuevamente para proteger tu cobro.");
    return;
  }
  openModal(
    "Tu viaje, con todo claro",
    `<div class="route-line">${I("circle-dot")}${e(q.origin)}</div><div class="route-line destination">${I("map-pin")}${e(q.destination)}</div><div class="estimate-grid"><div><small>Conductor a recogerte</small><strong>${decimal(q.pickup_distance_km)} km · ${q.pickup_eta_minutes} min</strong><span>${pickupBasis}</span></div><div><small>Tu recorrido</small><strong>${decimal(q.distance_km)} km · ${q.trip_eta_minutes} min</strong><span>${zoneLabel(q.service_zone)}</span></div></div><p class="hint">El precio usa la distancia y duración estimadas por el servidor. Puede variar en una nueva cotización por tráfico, cierre de calles o disponibilidad. ${q.scheduled_at ? "Programado: " + date(q.scheduled_at) : ""}</p><div class="fare-breakdown"><div class="receipt-row"><span>Inicio del servicio</span><span>${money(category?.base_cents)}</span></div><div class="receipt-row"><span>Distancia · ${decimal(q.distance_km)} km</span><span>${money(q.distance_charge_cents)}</span></div><div class="receipt-row"><span>Tiempo estimado · ${q.trip_eta_minutes} min</span><span>${money(q.time_charge_cents)}</span></div>${q.minimum_adjustment_cents ? `<div class="receipt-row"><span>Ajuste a tarifa mínima</span><span>${money(q.minimum_adjustment_cents)}</span></div>` : ""}${q.pickup_surcharge_cents ? `<div class="receipt-row"><span>Unidad elegida a más de 7 km · sólo excedente</span><span>${money(q.pickup_surcharge_cents)}</span></div>` : ""}${q.zone_surcharge_cents ? `<div class="receipt-row"><span>Ajuste por ${zoneLabel(q.service_zone).toLowerCase()}</span><span>${money(q.zone_surcharge_cents)}</span></div>` : ""}${q.accessibility_surcharge_cents ? `<div class="receipt-row"><span>Servicio para personas con alguna discapacidad</span><span>${money(q.accessibility_surcharge_cents)}</span></div>` : ""}<div class="receipt-row"><span>Propina voluntaria</span><strong id="tip-preview">$0.00</strong></div><div class="receipt-row total"><span>Total</span><strong id="total-preview">${money(q.fare_cents)}</strong></div></div><form id="payment"><h3>Agrega una propina (opcional)</h3><div class="tip-options"><label><input type="radio" name="tip" value="0" checked>Sin propina</label><label><input type="radio" name="tip" value="10">10%</label><label><input type="radio" name="tip" value="15">15%</label><label><input type="radio" name="tip" value="custom">Otro</label></div><label id="custom-tip-label" class="hidden">Propina (MXN)<input name="custom_tip" type="number" min="1" max="1000" step="0.01"></label><h3>¿Cómo quieres pagar?</h3><label class="check"><input type="radio" name="payment_method" value="cash" checked>Efectivo al finalizar el viaje</label><label class="check ${S.cardEnabled ? "" : "muted"}"><input type="radio" name="payment_method" value="card" ${S.cardEnabled ? "" : "disabled"}>Tarjeta con Mercado Pago ${S.cardEnabled ? "" : "· lista para activar"}</label><p class="hint">Los datos de tarjeta se capturan en el formulario seguro de Mercado Pago y Yavoi! no recibe ni almacena el número o CVV.</p><div id="cash-options"><label class="check"><input id="need-change" type="checkbox">Voy a necesitar cambio</label><label id="tender-label" class="hidden">Pagaré con (MXN)<input name="cash_tender" type="number" step="0.01" min="${q.fare_cents / 100}" max="3000" value="${q.fare_cents / 100}"></label><p id="change-preview" class="hint">Paga el importe exacto al llegar a tu destino.</p></div><button class="btn wide" type="submit">Confirmar y solicitar ${I("arrow-right")}</button></form>`,
  );
  const tipCents = () => {
    const choice = $('[name=tip]:checked').value;
    return choice === "custom" ? cents($('[name=custom_tip]').value || 0) : Math.round(q.fare_cents * Number(choice) / 100);
  };
  const updateTotal = () => {
    let tip = 0;
    try { tip = tipCents(); } catch {}
    $("#custom-tip-label").classList.toggle("hidden", $('[name=tip]:checked').value !== "custom");
    $("#tip-preview").textContent = money(tip);
    $("#total-preview").textContent = money(q.fare_cents + tip);
    $('[name=cash_tender]').min = (q.fare_cents + tip) / 100;
    if (!$("#need-change").checked) $('[name=cash_tender]').value = (q.fare_cents + tip) / 100;
    updateChange();
  };
  $$('[name=tip]').forEach((input) => input.onchange = updateTotal);
  $('[name=custom_tip]').oninput = updateTotal;
  $$('[name=payment_method]').forEach((input) => input.onchange = () => $("#cash-options").classList.toggle("hidden", input.value === "card" && input.checked));
  $("#need-change").onchange = (ev) => {
    $("#tender-label").classList.toggle("hidden", !ev.target.checked);
    if (!ev.target.checked) $("[name=cash_tender]").value = q.fare_cents / 100;
    updateChange();
  };
  function updateChange() {
    try {
      $("#change-preview").textContent =
        "Cambio estimado: " + money(changeDue(q.fare_cents + tipCents(), cents($("[name=cash_tender]").value)));
    } catch {}
  }
  $("[name=cash_tender]").oninput = updateChange;
  const requestKey = crypto.randomUUID();
  bindForm("#payment", async (v) => {
    const tip = tipCents();
    const method = v.payment_method;
    const total = q.fare_cents + tip;
    const t = await rpc("request_trip", {
      quote_id: q.id,
      request_key: requestKey,
      payment_method: method,
      cash_tender_cents: method === "cash" ? ($("#need-change").checked ? cents(v.cash_tender) : total) : null,
      tip_cents: tip,
      preferred_driver_id: q.preferred_driver_id,
    });
    closeModal();
    S.quote = null;
    S.data.ride_draft = null;
    if (method === "card") return cardCheckout(t.payment_id, t.id, total);
    S.data = await rpc("dashboard");
    location.hash = "trip/" + t.id;
  });
}
async function loadMercadoPago() {
  if (window.MercadoPago) return;
  await new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = "https://sdk.mercadopago.com/js/v2";
    script.onload = resolve;
    script.onerror = () => reject(new Error("No pudimos cargar el formulario seguro de Mercado Pago."));
    document.head.append(script);
  });
}
async function cardCheckout(paymentId, tripId, amountCents) {
  openModal("Pago seguro con tarjeta", `<div class="secure-payment">${I("shield-check")} Mercado Pago procesa los datos de tu tarjeta.</div><div id="card-payment-brick"><div class="hint">Cargando formulario seguro…</div></div>`);
  try {
    await loadMercadoPago();
    const mp = new window.MercadoPago(S.mercadoPagoPublicKey, { locale: "es-MX" });
    S.mpController = await mp.bricks().create("cardPayment", "card-payment-brick", {
      initialization: { amount: amountCents / 100, payer: { email: S.user.email } },
      customization: { visual: { style: { theme: "default" } }, paymentMethods: { maxInstallments: 1 } },
      callbacks: {
        onReady: () => {},
        onError: () => notify("Revisa el formulario seguro de la tarjeta."),
        onSubmit: async (formData) => {
          const { data, error } = await db.functions.invoke("mercado-pago-payment", { body: { payment_id: paymentId, form_data: formData } });
          if (error || data?.error) throw new Error(data?.error || error.message);
          closeModal();
          S.data = await rpc("dashboard");
          location.hash = "trip/" + tripId;
          notify(data.status === "approved" ? "Pago aprobado. Buscamos tu unidad." : "Mercado Pago está confirmando el pago.");
        },
      },
    });
  } catch (error) {
    closeModal();
    notify(errorMessage(error));
    location.hash = "trip/" + tripId;
  }
}
function stats() {
  const ts = S.data.trips,
    completed = ts.filter((t) => t.status === "completed");
  const gross = completed.reduce((n, t) => n + (t.total_cents || t.fare_cents), 0);
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
function driverSafetyMarkup() {
  const reports = (S.data.complaints || []).slice(0, 3);
  return `<section class="panel section-gap driver-safety"><div><div class="eyebrow">AYUDA Y SEGURIDAD</div><h2>Asistencia desde Conducir</h2><p>Registra un incidente para seguimiento de Operaciones. Si existe peligro inmediato, llama directamente a emergencias.</p></div><div class="driver-safety-buttons">${button("Crear reporte", "complaint", "secondary", "message-square-warning")}<a class="btn danger" href="tel:911">${I("phone-call")} Emergencias 911</a></div>${reports.length ? `<details><summary>Mis reportes recientes</summary>${reports.map((report) => `<article class="audit-item"><div class="row between"><strong>${e(report.subject)}</strong><span class="badge ${report.status === "resolved" ? "" : "pending"}">${e({ open: "Abierto", reviewing: "En revisión", resolved: "Resuelto" }[report.status] || report.status)}</span></div><small>${date(report.created_at)} · ${e(report.id.slice(0, 8))}</small>${report.response ? `<p class="hint">Respuesta: ${e(report.response)}</p>` : ""}</article>`).join("")}</details>` : ""}</section>`;
}
async function driverHome() {
  const activeTrip = S.data.trips.find((trip) => trip.driver_id === S.user.id && active(trip));
  if (activeTrip) {
    location.hash = "trip/" + activeTrip.id;
    return;
  }
  const driver = S.driver;
  if (!driver?.approved) {
    shell(
      `<section class="panel"><span class="badge pending">Expediente pendiente de aprobación</span><h2 class="section-gap">Tu próximo paso: completa tu perfil</h2><p>Necesitamos tu fotografía, licencia, seguro y datos de la unidad. Operaciones revisará el expediente antes de que puedas recibir viajes.</p>${driver?.review_note ? `<p class="hint">${e(driver.review_note)}</p>` : ""}<a class="btn" href="#profile">Completar mi expediente ${I("arrow-right")}</a></section>${driverSafetyMarkup()}`,
      "Hola, " + e(S.profile.full_name.split(" ")[0]),
      "Tu actividad como conductor comienza con una revisión de seguridad.",
    );
    return;
  }
  if (!driver.account_active) {
    shell(
      `<section class="panel"><span class="badge cancelled">Cuenta sin acceso a viajes</span><h2 class="section-gap">Revisa tu cuota semanal</h2><p>Tu cuenta no puede conectarse hasta que Operaciones valide la cuota o reactive el acceso.</p><a class="btn" href="#profile">Consultar cuota en mi perfil ${I("arrow-right")}</a></section>${driverSafetyMarkup()}`,
      "Acceso temporalmente desactivado",
      "Tu historial y tu perfil siguen disponibles.",
    );
    return;
  }
  const offers = await rpc("offers");
  await Promise.all(offers.map((offer) => loadAvatar(offer.passenger_avatar_path)));
  announceOffers(offers);
  const notificationButton =
    "Notification" in window && Notification.permission !== "granted"
      ? button("Activar avisos", "notifications", "secondary", "bell-ring")
      : "";
  const availabilityActions = `<div class="driver-actions">${button(driver.online ? "Desconectarme" : "Conectarme", "availability", driver.online ? "secondary" : "", "power")}${driver.online ? button("Actualizar ubicación", "presence", "secondary", "locate-fixed") : ""}${notificationButton}</div>`;
  const offerCards = offers.length
    ? offers
        .map(
          (offer) =>
            `<article class="offer targeted-offer"><div class="offer-passenger">${avatar(offer.passenger_name, offer.passenger_avatar_path, "big")}<div><small>Pasajero</small><h3>${e(offer.passenger_name)}</h3><p>${offer.passenger_rating ? `${decimal(offer.passenger_rating)}/5` : "Sin evaluaciones"} · ${offer.passenger_trips} viaje${Number(offer.passenger_trips) === 1 ? "" : "s"} completado${Number(offer.passenger_trips) === 1 ? "" : "s"}</p></div><div class="offer-expiry">${I("timer")}<span>Responde antes de<br><strong>${date(offer.expires_at)}</strong></span></div></div><div class="row between"><span class="badge neutral">Yavoi! ${e(S.categories.find((category) => category.id === offer.category)?.name || offer.category)}</span><strong class="earn">Ganas ${money(offer.net_cents)}</strong></div><div class="route-line">${I("circle-dot")}${e(offer.origin)}</div><div class="route-line destination">${I("map-pin")}${e(offer.destination)}</div><div class="estimate-grid compact"><div><small>Para recoger</small><strong>${offer.pickup_from_driver_km == null ? "Actualiza tu ubicación" : `${decimal(offer.pickup_from_driver_km)} km`}</strong></div><div><small>Viaje estimado</small><strong>${decimal(offer.distance_km)} km · ${offer.trip_eta_minutes} min</strong></div></div><div class="request-details"><div>${I("users-round")}<span><small>Personas</small><strong>${offer.party_size}</strong></span></div><div>${I("banknote")}<span><small>Pago</small><strong>${offer.payment_method === "card" ? "Tarjeta aprobada" : `Efectivo · paga con ${money(offer.cash_tender_cents)}`}</strong></span></div></div>${offer.service_notes ? `<div class="service-request">${I("message-square-text")}<div><small>Petición del pasajero</small><strong>${e(offer.service_notes)}</strong></div></div>` : ""}<div class="meta-row"><span>${zoneLabel(offer.service_zone)}</span><span>Total ${money(offer.total_cents || offer.fare_cents)}</span>${offer.payment_method === "cash" ? `<span>Cambio ${money(changeDue(offer.total_cents || offer.fare_cents, offer.cash_tender_cents))}</span>` : ""}${offer.tip_cents ? `<span>Incluye propina ${money(offer.tip_cents)}</span>` : ""}${offer.women_only ? "<span>Conductora verificada</span>" : ""}${offer.accessible ? "<span>Accesibilidad requerida</span>" : ""}</div><div class="offer-decisions"><button class="btn danger" data-reject-offer="${e(offer.offer_id)}">Rechazar ${I("x")}</button><button class="btn" data-accept-offer="${e(offer.offer_id)}">Aceptar viaje ${I("arrow-right")}</button></div></article>`,
        )
        .join("")
    : `<div class="empty">${I("navigation")}<h3>${driver.online ? "Esperando una solicitud compatible" : "Estás desconectado"}</h3><p>${driver.online ? "Tu presencia se renueva automáticamente. Cuando una solicitud llegue, verás sus datos aquí y recibirás un aviso si autorizaste las notificaciones." : "Conéctate para que el sistema pueda enviarte una solicitud por cercanía y disponibilidad."}</p></div>`;
  shell(
    `<div class="driver-banner"><div><div class="eyebrow">TU DISPONIBILIDAD</div><h2>${driver.online ? "Listo para tu próximo viaje" : "Tú eliges cuándo comenzar"}</h2><p>${driver.online ? "Yavoi! actualiza tu presencia y ubicación mientras esta página permanece abierta." : "Conéctate cuando estés listo para recibir solicitudes dirigidas a tu unidad."}</p></div>${availabilityActions}</div>${stats()}<section class="panel section-gap"><div class="row between offer-heading"><div><h2>Solicitud para ti</h2><p class="muted">Tienes 60 segundos para revisar al pasajero, sus necesidades, el recorrido y el pago.</p></div>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div>${offerCards}</section>${driverSafetyMarkup()}`,
    "Un buen día para conducir.",
    "Tu tiempo, tus viajes y tus ganancias en un mismo lugar.",
  );
  $$('[data-accept-offer]').forEach((item) => {
    item.onclick = () =>
      run(async () => {
        const trip = await rpc("accept", { offer_id: item.dataset.acceptOffer });
        if (trip.error) throw Error(trip.error);
        location.hash = "trip/" + trip.id;
      });
  });
  $$('[data-reject-offer]').forEach((item) => {
    item.onclick = () =>
      run(async () => {
        await rpc("reject_offer", {
          offer_id: item.dataset.rejectOffer,
          reason: "El conductor revisó la solicitud y decidió no tomarla",
        });
        await refreshPage();
        notify("Solicitud rechazada. Yavoi! buscará la siguiente unidad disponible.");
      });
  });
}
function tableTrips() {
  return `<div class="table-wrap"><table><thead><tr><th>Folio / fecha</th><th>Recorrido</th><th>Estado</th><th>Pago</th><th>Importe</th><th></th></tr></thead><tbody id="trip-rows">${tripRows(S.data.trips)}</tbody></table></div>${!S.data.trips.length ? `<div class="empty">${I("route")}<h3>Tu historial empieza con el primer viaje</h3><p>Los viajes guardados aparecerán aquí.</p></div>` : ""}`;
}
function tripRows(ts) {
  return ts
    .map(
      (t) =>
        `<tr><td><strong>${e(t.id.slice(0, 8).toUpperCase())}</strong><small>${date(t.created_at)}</small></td><td>${e(t.origin)}<small>${e(t.destination)}</small></td><td>${badge(t)}</td><td>${t.payment_method === "card" ? "Tarjeta" : "Efectivo"}<small>${e({ paid: "Confirmado", pending: "Pendiente", failed: "No aprobado", refund_pending: "Reembolso pendiente", refunded: "Reembolsado" }[t.payment_status] || t.payment_status)}</small></td><td>${money(t.total_cents || t.fare_cents)}</td><td><a class="link" href="#trip/${e(t.id)}">Ver viaje</a></td></tr>`,
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
  const title = statuses[t.status] || t.status;
  const progress = ["requested", "accepted", "arrived", "in_progress", "completed"].indexOf(
    t.status,
  );
  const ridePayment = S.trip.payments?.find((payment) => payment.kind === "ride");
  const action =
    t.status === "payment_pending" && rider && ridePayment
      ? `${button("Continuar pago seguro", "retry-card", "wide", "credit-card")}${button("Cancelar solicitud", "cancel", "danger wide section-gap", "x")}`
      : t.status === "accepted" && conductor
      ? button("Ya llegué al punto", "arrive", "wide", "map-pin")
      : t.status === "arrived" && conductor
        ? `<form id="start-trip"><label>PIN del pasajero<input name="pin" inputmode="numeric" autocomplete="off" pattern="[0-9]{4}" minlength="4" maxlength="4" required placeholder="4 dígitos"></label><button class="btn wide" type="submit">Iniciar viaje ${I("navigation")}</button></form>`
        : t.status === "in_progress" && conductor
          ? button("Llegamos al destino", "finish", "wide", "flag")
          : "";
  const statusMessage =
    t.status === "payment_pending" ? "Completa o espera la confirmación de Mercado Pago antes de asignar una unidad."
      : t.status === "requested" ? "Buscamos un conductor disponible que cumpla tus preferencias."
        : t.status === "scheduled" ? "Tu solicitud se asignará cerca de la hora programada."
          : t.status === "accepted" ? "Verifica la fotografía, el color, el modelo y las placas antes de abordar."
            : t.status === "arrived" ? "Comparte el PIN sólo cuando estés frente al conductor correcto."
              : t.status === "in_progress" ? "Sigue el recorrido en el mapa y comunícate con tu conductor."
                : t.status === "completed" ? "Gracias por viajar con Yavoi! Tu opinión nos ayuda a mejorar."
                  : "La solicitud fue cancelada.";
  const serviceDetails = `<div class="service-summary"><div>${I("users-round")}<span><small>Personas</small><strong>${t.party_size || 1}</strong></span></div><div>${I(t.accessible ? "accessibility" : "car-front")}<span><small>Servicio</small><strong>Yavoi! ${e(S.categories.find((category) => category.id === t.category)?.name || t.category)}</strong></span></div>${t.service_notes ? `<div class="wide-detail">${I("message-square-text")}<span><small>Petición del pasajero</small><strong>${e(t.service_notes)}</strong></span></div>` : ""}</div>`;
  let paymentRows = serviceDetails + (t.payment_method === "card"
    ? `<div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${t.tip_cents ? `<div class="receipt-row"><span>Propina</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total · tarjeta</span><strong>${money(t.total_cents || t.fare_cents)}</strong></div><p class="hint">Estado del pago: ${e({ paid: "Confirmado", pending: "En proceso", failed: "No aprobado", refund_pending: "Reembolso en proceso", refunded: "Reembolsado" }[t.payment_status] || t.payment_status)}</p>`
    : `<div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${t.tip_cents ? `<div class="receipt-row"><span>Propina voluntaria</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total · efectivo</span><strong>${money(t.total_cents || t.fare_cents)}</strong></div><div class="receipt-row"><span>Pago con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row"><span>Cambio</span><strong>${money(changeDue(t.total_cents || t.fare_cents, t.cash_tender_cents))}</strong></div>`);
  if (S.profile.role === "admin" && S.trip.operations) {
    const operations = S.trip.operations;
    const expected = Number(t.total_cents || t.fare_cents || 0);
    const collected = Number(operations.paid_cents || 0);
    const difference = collected - expected;
    const ledger = operations.ledger || [];
    paymentRows += `<section class="reconciliation"><div class="row between"><h3>Conciliación del viaje</h3><span class="badge ${difference === 0 && collected > 0 ? "" : "pending"}">${difference === 0 && collected > 0 ? "Conciliado" : t.status === "completed" ? "Revisar diferencia" : "En proceso"}</span></div><div class="receipt-row"><span>Importe esperado</span><strong>${money(expected)}</strong></div><div class="receipt-row"><span>Cobro confirmado</span><strong>${money(collected)}</strong></div><div class="receipt-row"><span>Diferencia</span><strong>${money(difference)}</strong></div><div class="receipt-row"><span>Ingreso neto del conductor</span><strong>${money(operations.driver_net_cents)}</strong></div><div class="receipt-row"><span>Método y estado</span><strong>${t.payment_method === "card" ? "Mercado Pago" : "Efectivo"} · ${e(t.payment_status)}</strong></div><div class="receipt-row"><span>Eventos del proveedor</span><strong>${(operations.payment_events || []).length}</strong></div><p class="hint">Pasajero: ${e(passenger?.name || "Sin dato")} · ${e(operations.passenger_phone || "sin teléfono")}<br>Conductor: ${e(driver?.name || "Sin asignar")} · ${e(operations.driver_phone || "sin teléfono")}<br>Movimientos contables: ${ledger.length}</p></section>`;
  }
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
  const tripSafetyControls =
    conductor && active(t)
      ? `<section class="ride-safety-actions" aria-label="Ayuda y seguridad durante el viaje"><button class="btn secondary" data-action="trip-report">${I("message-square-warning")} Reportar viaje</button><a class="btn danger" href="tel:911">${I("phone-call")} Emergencias 911</a></section>`
      : "";
  const tripFooter = `<div class="row wrap section-gap">${button("Compartir resumen", "share", "secondary", "share-2")}${conductor ? "" : `<a href="#help" class="btn secondary">${I("headset")} Ayuda</a>`}</div>`;
  shell(
    `<div class="trip-layout"><section class="panel trip-panel">${badge(t)}<h2 class="big-status">${e(title)}</h2><p>${e(statusMessage)}</p><div class="stepper" aria-hidden="true">${[0, 1, 2, 3, 4].map((i) => `<span class="${i <= progress ? "done" : ""}"></span>`).join("")}</div><div class="route-line">${I("circle-dot")}${e(t.origin)}</div><div class="route-line destination">${I("map-pin")}${e(t.destination)}</div>${t.scheduled_at ? `<p class="hint">${I("calendar")} ${date(t.scheduled_at)}</p>` : ""}${person ? `<div class="person-card">${avatar(person.name, person.avatar_path, "big")}<div><small>${rider ? "Tu conductor" : "Tu pasajero"}</small><strong style="display:block;margin-top:5px">${e(person.name)}</strong>${rider ? `<p>${e([driver.vehicle_color, driver.vehicle_make, driver.vehicle_model, driver.vehicle_year].filter(Boolean).join(" ") || driver.vehicle)} · ${e(driver.plate)}</p><small>Calificación: ${driver.rating || "Nuevo conductor"}</small>` : ""}</div></div>` : ""}${pin ? `<div class="pin-card"><span>Tu PIN de inicio<br><small>No lo compartas antes de abordar</small></span><strong>${e(pin)}</strong></div>` : ""}${t.distance_km != null ? `<div class="estimate-grid compact"><div><small>Recogida estimada</small><strong>${decimal(t.pickup_distance_km)} km · ${t.pickup_eta_minutes} min</strong></div><div><small>Recorrido estimado</small><strong>${decimal(t.distance_km)} km · ${t.trip_eta_minutes} min</strong><span>${zoneLabel(t.service_zone)}</span></div></div>` : ""}${paymentRows}${action}${tripSafetyControls}${conductor && active(t) && t.status !== "payment_pending" ? `<div class="section-gap">${button("Actualizar ubicación ahora", "gps", "secondary wide", "locate-fixed")}<p class="hint">La ubicación se actualiza automáticamente mientras Yavoi! permanece abierto y se recupera al volver a la página.</p></div>` : ""}${t.status === "completed" && !my_rating && (rider || conductor) ? button(rider ? "Valorar viaje y conductor" : "Valorar pasajero", "rate", "wide", "star") : ""}${my_rating ? `<p class="hint">Evaluación enviada: ${my_rating.stars}/5. Gracias por compartir tu experiencia.</p>` : ""}${t.status === "completed" && conductor ? button("Registrar propina recibida", "tip", "secondary wide section-gap", "heart") : ""}${t.status === "completed" && rider ? button("Agregar propina", "passenger-tip", "secondary wide section-gap", "heart") : ""}${t.status === "completed" ? button("Ver recibo", "receipt", "secondary wide section-gap", "receipt-text") : ""}${active(t) && t.status !== "in_progress" && t.status !== "payment_pending" ? button("Cancelar viaje", "cancel", "danger wide section-gap", "x") : ""}${S.profile.role === "admin" && t.status === "arrived" ? button("Renovar PIN bloqueado", "reset-pin", "secondary wide section-gap", "key-round") : ""}${S.profile.role === "admin" && t.status === "in_progress" ? button("Cancelar por incidencia", "cancel", "danger wide section-gap", "shield-alert") : ""}${tripFooter}</section><div class="stack">${mapFrame("ride-map", e(geo))}<section class="panel"><h2>Mensajes del viaje</h2><div id="chat" class="chat">${messagesHtml(S.trip.messages)}</div>${conductor || rider ? `<form id="chat-form" class="chat-form"><input name="body" aria-label="Mensaje" placeholder="Escribe un mensaje…" required maxlength="1000" ${!t.driver_id || !active(t) ? "disabled" : ""}><button class="btn" type="submit" aria-label="Enviar mensaje" ${!t.driver_id || !active(t) ? "disabled" : ""}>${I("send")}</button></form>` : ""}<p class="hint">Para una emergencia real, llama al <a href="tel:911" class="link">911</a>. El chat no es un servicio de atención inmediata.</p></section></div></div>`,
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
    : completed.reduce((n, t) => n + (t.total_cents || t.fare_cents), 0);
  shell(
    `<div class="balance"><small>${driver ? "INGRESO NETO REGISTRADO" : "TOTAL DE VIAJES COMPLETADOS"}</small><h2>${money(total)}</h2><p>${driver ? "Tarifas cobradas, menos comisión, más propinas recibidas." : "Pagos en efectivo registrados por el conductor al terminar."}</p></div><div class="grid2"><section class="panel"><h2>${driver ? "Tus movimientos" : "Métodos de pago"}</h2>${driver ? (S.data.ledger.length ? S.data.ledger.map((l) => `<div class="receipt-row"><div>${e({ fare: "Tarifa cobrada", commission: "Comisión por pagar", cash_tip: "Propina en efectivo" }[l.kind])}<small style="display:block">${date(l.created_at)}</small></div><strong>${money(l.amount_cents)}</strong></div>`).join("") : "<p>Aún no hay movimientos.</p>") : `<div class="row">${I("banknote")}<strong>Efectivo</strong><span class="badge">Disponible</span></div><p class="hint">Indica si necesitas cambio antes de solicitar. El conductor verá el monto con el que pagarás.</p><div class="row muted">${I("credit-card")}<strong>Tarjeta</strong><span class="badge neutral">Próximamente</span></div><p class="hint">No se guardan datos de tarjeta. Esta opción se activará al conectar un proveedor de pagos.</p>`}</section><section class="panel"><h2>${driver ? "Comisiones y liquidaciones" : "Cada peso, con claridad"}</h2><p>${driver ? "Al cobrar en efectivo recibes la tarifa completa. La comisión registrada representa una cuenta pendiente con Yavoi!, no una transferencia ya realizada." : "La tarifa se muestra antes de confirmar. La propina es voluntaria y puedes entregarla directamente en efectivo."}</p><p class="hint">No hay retiros bancarios, cobros automáticos ni devoluciones electrónicas habilitados. Operaciones deberá conciliar el efectivo.</p><a class="btn secondary" href="#trips">Consultar mis viajes ${I("arrow-right")}</a></section></div>`,
    driver ? "Tus ingresos, siempre claros." : "Tu cartera Yavoi!",
    "Consulta los importes registrados en tus viajes.",
  );
  if (!driver && S.cardEnabled) {
    const cardRow = $(".row.muted");
    cardRow?.classList.remove("muted");
    const cardBadge = $(".badge", cardRow);
    if (cardBadge) cardBadge.textContent = "Disponible";
    const note = cardRow?.nextElementSibling;
    if (note) note.textContent = "Tarjeta protegida por Mercado Pago, disponible al solicitar el viaje y para propinas posteriores.";
  }
}
function weeklyProfileMarkup() {
  const fees = S.data.weekly_fees || [];
  const current = fees[0];
  const statusName = { pending: "Pendiente", submitted: "En revisión", paid: "Pagada", overdue: "Vencida", waived: "Condonada" };
  return `<details class="profile-section weekly-profile" open><summary><span>${I("calendar-check")}<strong>Cuota semanal</strong></span><span class="badge ${current && ["pending", "submitted", "overdue"].includes(current.status) ? "pending" : ""}">${current ? e(statusName[current.status]) : "Sin cuota activa"}</span></summary><div class="weekly-summary"><div><small>CUOTA SEMANAL DE USO</small><strong>${money(current?.amount_cents || 50000)}</strong><p>${current ? `Semana del ${new Date(current.week_start + "T12:00:00").toLocaleDateString("es-MX", { dateStyle: "long" })} · vence ${date(current.due_at)}` : "La cuota aparecerá al aprobarse tu expediente."}</p></div></div><div class="grid2 weekly-grid"><section><h3>Semana actual</h3>${current && !["paid", "waived"].includes(current.status) ? `<form id="weekly-proof"><p>Sube el comprobante de pago de $500. Operaciones verificará el depósito y habilitará la cuenta.</p><label>Comprobante · PDF, JPG o PNG hasta 5 MB<input name="proof" type="file" accept="application/pdf,image/jpeg,image/png" required></label><button class="btn wide" type="submit">Enviar comprobante ${I("upload")}</button></form>` : `<p>${current ? "Tu cuota de esta semana está cubierta." : "Aún no existe una cuota activa."}</p>`}</section><section><h3>Calendario de cuotas</h3>${fees.length ? fees.map((fee) => `<div class="fee-row"><div><strong>${new Date(fee.week_start + "T12:00:00").toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" })}</strong><small>Vence ${date(fee.due_at)}</small></div><span class="badge ${["pending", "submitted", "overdue"].includes(fee.status) ? "pending" : ""}">${e(statusName[fee.status])}</span><strong>${money(fee.amount_cents)}</strong></div>`).join("") : '<p class="muted">Sin cuotas registradas.</p>'}</section></div></details>`;
}
function bindWeeklyProof() {
  const current = (S.data.weekly_fees || [])[0];
  bindForm("#weekly-proof", async (_v, form) => {
    const path = await upload(form.elements.proof.files[0], "yavoi-payment-proofs");
    await rpc("submit_weekly_fee", { fee_id: current.id, proof_path: path });
    await refreshPage();
    notify("Comprobante enviado a Operaciones.");
  });
}
function paymentsView() {
  const payments = S.data.payments || [];
  const fees = S.data.weekly_fees || [];
  const approved = payments.filter((payment) => payment.status === "approved").reduce((sum, payment) => sum + payment.amount_cents, 0);
  const statusName = { created: "Creado", pending: "Pendiente", in_process: "Procesando", approved: "Aprobado", rejected: "Rechazado", cancelled: "Cancelado", refund_pending: "Reembolso pendiente", refunded: "Reembolsado", submitted: "En revisión", paid: "Pagada", overdue: "Vencida", waived: "Condonada" };
  shell(
    `<div class="grid4 stats"><div class="stat"><small>Pagos registrados</small><strong>${payments.length}</strong><p>Efectivo, tarjeta y cuotas</p></div><div class="stat"><small>Importe aprobado</small><strong>${money(approved)}</strong><p>Conciliación del sistema</p></div><div class="stat"><small>Cuotas por revisar</small><strong>${fees.filter((fee) => fee.status === "submitted").length}</strong><p>Comprobantes recibidos</p></div><div class="stat"><small>Reembolsos pendientes</small><strong>${payments.filter((payment) => payment.status === "refund_pending").length}</strong><p>Requieren seguimiento</p></div></div><section class="panel section-gap"><h2>Registro de pagos</h2><div class="table-wrap"><table><thead><tr><th>Fecha / referencia</th><th>Concepto</th><th>Viaje y personas</th><th>Método</th><th>Estado</th><th>Importe</th><th></th></tr></thead><tbody>${payments.map((payment) => `<tr><td>${date(payment.created_at)}<small>${e(payment.provider_payment_id || payment.id.slice(0, 8))}</small></td><td>${e({ ride: "Viaje", tip: "Propina", weekly_fee: "Cuota semanal" }[payment.kind])}</td><td>${e(payment.origin || "Sin viaje")}<small>${e(payment.payer_name || "")} ${payment.driver_name ? `· ${e(payment.driver_name)}` : ""}</small></td><td>${e({ cash: "Efectivo", mercado_pago: "Mercado Pago", manual: "Comprobante" }[payment.provider])}</td><td><span class="badge ${["created", "pending", "in_process", "refund_pending"].includes(payment.status) ? "pending" : payment.status === "rejected" ? "cancelled" : ""}">${e(statusName[payment.status] || payment.status)}</span></td><td><strong>${money(payment.amount_cents)}</strong></td><td>${payment.status === "refund_pending" ? `<button class="link" data-refund="${e(payment.id)}">Procesar reembolso</button>` : ""}</td></tr>`).join("")}</tbody></table></div></section><section class="panel section-gap"><h2>Cuotas semanales de conductores</h2>${fees.length ? fees.map((fee) => `<article class="fee-card"><div><strong>${e(fee.driver_name)}</strong><small>Semana ${e(fee.week_start)} · vence ${date(fee.due_at)}</small></div><strong>${money(fee.amount_cents)}</strong><span class="badge ${["pending", "submitted", "overdue"].includes(fee.status) ? "pending" : ""}">${e(statusName[fee.status])}</span><div class="row wrap">${fee.proof_path ? `<button class="btn secondary" data-fee-proof="${e(fee.proof_path)}">Ver comprobante</button>` : ""}${fee.status === "submitted" ? `<button class="btn" data-fee-review="${e(fee.id)}">Revisar pago</button>` : ""}<button class="btn ${fee.account_active ? "danger" : "secondary"}" data-driver-access="${e(fee.driver_id)}" data-active="${fee.account_active ? "false" : "true"}">${fee.account_active ? "Desactivar cuenta" : "Activar cuenta"}</button></div></article>`).join("") : '<div class="empty"><p>No hay cuotas registradas.</p></div>'}</section>`,
    "Pagos y cuotas",
    "Conciliación por viaje, conductor, pasajero y semana.",
  );
  $$('[data-fee-proof]').forEach((item) => item.onclick = () => run(async () => {
    const { data, error } = await db.storage.from("yavoi-payment-proofs").createSignedUrl(item.dataset.feeProof, 60);
    if (error) throw error;
    openModal("Comprobante privado", `<p>El enlace vence en un minuto.</p><a class="btn wide" href="${e(data.signedUrl)}" target="_blank" rel="noopener noreferrer">Abrir comprobante ${I("external-link")}</a>`);
  }));
  $$('[data-fee-review]').forEach((item) => item.onclick = () => {
    openModal("Revisar cuota semanal", `<form id="fee-review"><label>Resultado<select name="approved"><option value="true">Pago comprobado</option><option value="false">Rechazar comprobante</option></select></label><label>Nota de revisión<textarea name="note" minlength="5" maxlength="1000" required></textarea></label><button class="btn wide" type="submit">Guardar revisión</button></form>`);
    bindForm("#fee-review", async (values) => {
      await rpc("review_weekly_fee", { fee_id: item.dataset.feeReview, approved: values.approved === "true", note: values.note });
      closeModal();
      await refreshPage();
    });
  });
  $$('[data-driver-access]').forEach((item) => item.onclick = () => run(async () => {
    await rpc("set_driver_access", { driver_id: item.dataset.driverAccess, active: item.dataset.active === "true", note: "Cambio desde control de cuotas" });
    await refreshPage();
  }));
  $$('[data-refund]').forEach((item) => item.onclick = () => run(async () => {
    const { data, error } = await db.functions.invoke("mercado-pago-payment", { body: { action: "refund", payment_id: item.dataset.refund } });
    if (error || data?.error) throw new Error(data?.error || error.message);
    await refreshPage();
    notify("Reembolso confirmado por Mercado Pago.");
  }));
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
    bucket === "yavoi-documents" || bucket === "yavoi-payment-proofs"
      ? ["application/pdf", "image/jpeg", "image/png"]
      : ["image/jpeg", "image/png", "image/webp"];
  if (!types.includes(file.type)) throw Error("Elige un archivo del formato permitido.");
  if (file.size > (bucket === "yavoi-documents" || bucket === "yavoi-payment-proofs" ? 5 : 2) * 1024 * 1024)
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
function driverProgressMarkup(profile, driver) {
  const status = driverDossierStatus(profile, driver);
  const missing = status.missing.length
    ? `Faltan ${status.missing.length}: ${status.missing.slice(0, 3).join(", ")}${status.missing.length > 3 ? " y otros requisitos" : ""}.`
    : "Expediente completo. Guarda el avance para enviarlo a Operaciones.";
  return `<section class="dossier-progress" aria-labelledby="dossier-progress-title"><div class="row between"><div><small id="dossier-progress-title">AVANCE DEL EXPEDIENTE</small><strong id="dossier-progress-label">${status.percent}% completo</strong></div><b id="dossier-progress-count">${status.completed} de ${status.total}</b></div><progress id="dossier-progress" max="100" value="${status.percent}">${status.percent}%</progress><p id="dossier-progress-missing">${e(missing)}</p></section>`;
}
function passengerProgressMarkup(profile) {
  const status = passengerProfileStatus(profile);
  const missing = status.missing.length
    ? `Faltan ${status.missing.length}: ${status.missing.join(", ")}.`
    : "Perfil completo. Ya puedes solicitar viajes.";
  return `<section class="dossier-progress passenger-progress" aria-labelledby="passenger-progress-title"><div class="row between"><div><small id="passenger-progress-title">AVANCE DEL PERFIL</small><strong id="passenger-progress-label">${status.percent}% completo</strong></div><b id="passenger-progress-count">${status.completed} de ${status.total}</b></div><progress id="passenger-progress" max="100" value="${status.percent}">${status.percent}%</progress><p id="passenger-progress-missing">${e(missing)}</p></section>`;
}
function passengerPolicyMarkup(profile) {
  const accepted =
    profile.passenger_policy_accepted_at &&
    profile.passenger_policy_version === PASSENGER_POLICY_VERSION;
  return `<section class="passenger-policy"><div class="row between"><div><div class="eyebrow">POLÍTICAS DE SEGURIDAD</div><h3>Reglas para viajar en Yavoi!</h3></div><span class="badge ${accepted ? "" : "pending"}">${accepted ? "Aceptadas" : "Pendientes"}</span></div><details ${accepted ? "" : "open"}><summary>Leer políticas obligatorias</summary><div class="policy-copy"><p>Al viajar, cada pasajero debe:</p><ul><li>Usar cinturón de seguridad durante todo el trayecto y asegurar correctamente a menores de edad.</li><li>Mantener limpia la unidad y responder por daños causados de forma intencional o negligente.</li><li>No fumar ni vapear, y no consumir alcohol, drogas, estupefacientes u otras sustancias dentro del vehículo.</li><li>No portar armas, materiales peligrosos ni objetos que pongan en riesgo a otras personas.</li><li>Tratar con respeto al conductor y a los acompañantes; no se permite acoso, discriminación, amenazas ni violencia.</li><li>Respetar la capacidad de la categoría, informar equipaje o carga especial y seguir las indicaciones de seguridad.</li><li>No distraer al conductor, interferir con la conducción ni pedir maniobras contrarias a la ley.</li><li>Estar listo en el punto acordado y verificar la placa, unidad y conductor antes de abordar.</li></ul><p>El conductor puede reportar incumplimientos. Ante una conducta grave o un riesgo inmediato, puede detenerse en un lugar seguro, cancelar el servicio y solicitar el descenso. Yavoi! puede revisar el caso, restringir la cuenta y compartir información con autoridades cuando exista obligación legal. En una emergencia llama al 911.</p></div></details><label class="check policy-accept"><input name="accept_passenger_policy" type="checkbox" ${accepted ? "checked" : ""} required>He leído y acepto estas políticas de seguridad, versión ${PASSENGER_POLICY_VERSION}.</label></section>`;
}
function documentField(name, title, path, note = "") {
  return `<label class="document-upload"><span>${e(title)}</span><input name="${name}" type="file" accept="application/pdf,image/jpeg,image/png"><small>${path ? "Documento recibido. Puedes reemplazarlo." : "Pendiente de cargar"}${note ? ` · ${e(note)}` : ""}</small></label>`;
}
function profileLockNotice(editState) {
  if (!editState.locked) return "";
  if (editState.authorized)
    return `<div class="profile-lock-notice authorized">${I("lock-open")}<div><strong>Edición autorizada por Operaciones</strong><p>Puedes actualizar tus datos hasta ${date(S.profile.profile_edit_allowed_until)}. Cada cambio queda registrado.</p></div></div>`;
  return `<div class="profile-lock-notice">${I("lock-keyhole")}<div><strong>Perfil protegido</strong><p>El expediente completo está disponible sólo para consulta. Operaciones debe autorizar cualquier modificación.</p></div></div>`;
}
function profile() {
  const p = S.profile;
  const d = S.driver || {};
  const driver = p.role === "driver";
  const passenger = p.role === "passenger";
  const dossier = driver ? driverDossierStatus(p, d) : null;
  const editState = profileEditState(p);
  const formDisabled = editState.editable ? "" : "disabled";
  const lockNotice = profileLockNotice(editState);
  const personalForm = `<form id="profile-form"><fieldset ${formDisabled}><div class="grid2"><label>Nombre completo<input name="name" autocomplete="name" required minlength="2" maxlength="100" value="${e(p.full_name)}"></label><label>Teléfono de contacto<input name="phone" type="tel" autocomplete="tel" required minlength="10" maxlength="25" value="${e(p.phone)}"></label><label>Contacto de emergencia<input name="emergency_name" ${passenger ? 'required minlength="2"' : ""} maxlength="100" value="${e(p.emergency_name)}"></label><label>Teléfono de emergencia<input name="emergency_phone" type="tel" ${passenger ? 'required minlength="10"' : ""} maxlength="25" value="${e(p.emergency_phone)}"></label></div><label>Fotografía de perfil · JPG, PNG o WebP, hasta 2 MB<input name="avatar" type="file" accept="image/jpeg,image/png,image/webp" ${passenger && !p.avatar_path ? "required" : ""}></label>${passenger ? passengerPolicyMarkup(p) : ""}<button type="submit" class="btn">Guardar perfil ${I("check")}</button></fieldset></form>`;
  const driverDossier = driver
    ? `<details class="profile-section dossier-details" ${dossier.percent < 100 ? "open" : ""}><summary><span>${I("car-front")}<strong>Mi unidad y documentos</strong></span><span class="badge ${d.approved ? "" : "pending"}">${d.approved ? "Aprobado" : dossier.percent === 100 ? "100% completo" : `${dossier.percent}% completo`}</span></summary><div class="profile-section-body">${driverProgressMarkup(p, d)}<p class="hint">Al modificar el expediente la autorización anterior se pausa hasta una nueva revisión. Los documentos son privados y sólo el conductor y Operaciones pueden consultarlos.</p>${d.review_note ? `<p class="hint">Revisión: ${e(d.review_note)}</p>` : ""}<form id="vehicle-form"><fieldset ${formDisabled}><h3>Datos de la unidad</h3><div class="grid2"><label>Marca<input name="vehicle_make" required minlength="2" maxlength="50" value="${e(d.vehicle_make)}" placeholder="Nissan"></label><label>Modelo<input name="vehicle_model" required minlength="1" maxlength="50" value="${e(d.vehicle_model)}" placeholder="Versa"></label><label>Año<input name="vehicle_year" type="number" min="1990" max="${new Date().getFullYear() + 1}" required value="${e(d.vehicle_year || "")}"></label><label>Color<input name="vehicle_color" required minlength="3" maxlength="40" value="${e(d.vehicle_color)}" placeholder="Gris"></label><label>Placas<input name="plate" required minlength="5" maxlength="20" value="${e(d.plate)}"></label><label>Categoría<select name="category">${S.categories.map((c) => `<option value="${c.id}" ${d.category === c.id ? "selected" : ""}>${e(c.name)}</option>`).join("")}</select></label><label>Número de licencia<input name="license_number" required maxlength="50" value="${e(d.license_number)}"></label><label>Vencimiento de licencia<input name="license_expires" type="date" required value="${e(d.license_expires)}"></label><label>Vencimiento de seguro<input name="insurance_expires" type="date" required value="${e(d.insurance_expires)}"></label></div><h3 class="section-gap">Documentos privados</h3><div class="driver-documents">${documentField("license_file", "Licencia de conducir", d.license_path)}${documentField("insurance_file", "Póliza de seguro", d.insurance_path)}${documentField("criminal_record_file", "Carta de no antecedentes penales", d.criminal_record_path, "carga el documento oficial vigente")}${documentField("policy_commitment_file", "Carta de compromiso y políticas Yavoi! firmada", d.policy_commitment_path)}${documentField("traffic_law_commitment_file", "Carta de aceptación de obligaciones viales firmada", d.traffic_law_commitment_path)}</div><div class="document-templates"><div>${I("file-down")}<span><strong>Plantillas para firma</strong><small>Descarga, completa, firma y carga el documento entero.</small></span></div><a class="btn secondary" href="/documents/carta-compromiso-politicas-yavoi.pdf" download>Políticas Yavoi! ${I("download")}</a><a class="btn secondary" href="/documents/carta-aceptacion-vialidad-chihuahua.pdf" download>Obligaciones viales ${I("download")}</a><a class="link" href="https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf" target="_blank" rel="noopener noreferrer">Consultar ley oficial ${I("external-link")}</a></div><label class="check"><input type="checkbox" name="advertising_interest" ${d.advertising_interest ? "checked" : ""}>Me interesa participar en convenios de publicidad</label><button type="submit" class="btn">Guardar y enviar expediente ${I("shield-check")}</button></fieldset></form></div></details>`
    : "";
  shell(
    `<section class="panel"><div class="profile-head">${avatar(p.full_name, p.avatar_path, "big")}<div><h2>${e(p.full_name)}</h2><p>${e(S.user.email)} · ${e(roles[p.role])}</p><small>El tipo de cuenta se protege en el servidor.</small></div></div>${passenger ? passengerProgressMarkup(p) : ""}${lockNotice}${personalForm}</section>${driverDossier}${driver ? weeklyProfileMarkup() : ""}<section class="panel section-gap"><h2>Acceso y seguridad</h2><p>Tu sesión es personal. Puedes cambiar tu contraseña o cerrar sesión en todos tus dispositivos.</p><div class="row wrap">${button("Cambiar contraseña", "password", "secondary", "key-round")}${button("Cerrar mis sesiones", "logout", "secondary", "log-out")}</div>${p.role === "admin" ? '<p class="hint">Operaciones exige autenticación en dos pasos. Conserva acceso a tu aplicación autenticadora.</p>' : ""}</section>`,
    "Mi perfil",
    "Tu información, tu unidad y las opciones de tu cuenta.",
  );
  if (editState.editable) {
    bindForm("#profile-form", async (v, f) => {
      const path = await upload(f.elements.avatar.files[0], "yavoi-avatars");
      await rpc("profile", {
        name: v.name,
        phone: v.phone,
        emergency_name: v.emergency_name,
        emergency_phone: v.emergency_phone,
        ...(path ? { avatar_path: path } : {}),
        accept_passenger_policy: v.accept_passenger_policy === "on",
        passenger_policy_version: PASSENGER_POLICY_VERSION,
      });
      await loadSession();
      notify("Perfil actualizado.");
    });
    bindForm("#vehicle-form", async (v, f) => {
      const [license, insurance, criminalRecord, policyCommitment, trafficLawCommitment] = await Promise.all([
        upload(f.elements.license_file.files[0], "yavoi-documents"),
        upload(f.elements.insurance_file.files[0], "yavoi-documents"),
        upload(f.elements.criminal_record_file.files[0], "yavoi-documents"),
        upload(f.elements.policy_commitment_file.files[0], "yavoi-documents"),
        upload(f.elements.traffic_law_commitment_file.files[0], "yavoi-documents"),
      ]);
      await rpc("driver_profile", {
        ...v,
        license_file: undefined,
        insurance_file: undefined,
        criminal_record_file: undefined,
        policy_commitment_file: undefined,
        traffic_law_commitment_file: undefined,
        ...(license ? { license_path: license } : {}),
        ...(insurance ? { insurance_path: insurance } : {}),
        ...(criminalRecord ? { criminal_record_path: criminalRecord } : {}),
        ...(policyCommitment ? { policy_commitment_path: policyCommitment } : {}),
        ...(trafficLawCommitment ? { traffic_law_commitment_path: trafficLawCommitment } : {}),
        advertising_interest: v.advertising_interest === "on",
      });
      await loadSession();
      notify("Expediente enviado a revisión.");
    });
  }
  if (passenger && editState.editable) {
    const form = $("#profile-form");
    const updatePassengerProgress = () => {
      const values = Object.fromEntries(new FormData(form));
      const snapshot = {
        ...p,
        full_name: values.name,
        phone: values.phone,
        emergency_name: values.emergency_name,
        emergency_phone: values.emergency_phone,
        avatar_path: form.elements.avatar.files?.[0] ? "selected" : p.avatar_path,
        passenger_policy_accepted_at: values.accept_passenger_policy === "on" ? new Date().toISOString() : null,
        passenger_policy_version: values.accept_passenger_policy === "on" ? PASSENGER_POLICY_VERSION : null,
      };
      const status = passengerProfileStatus(snapshot);
      $("#passenger-progress").value = status.percent;
      $("#passenger-progress-label").textContent = `${status.percent}% completo`;
      $("#passenger-progress-count").textContent = `${status.completed} de ${status.total}`;
      $("#passenger-progress-missing").textContent = status.missing.length
        ? `Faltan ${status.missing.length}: ${status.missing.join(", ")}.`
        : "Perfil completo. Guarda los cambios para solicitar viajes.";
    };
    form.addEventListener("input", updatePassengerProgress);
    form.addEventListener("change", updatePassengerProgress);
  }
  if (driver && editState.editable) {
    const form = $("#vehicle-form");
    const updateProgress = () => {
      const values = Object.fromEntries(new FormData(form));
      const snapshot = { ...d, ...values };
      const files = {
        license_path: "license_file",
        insurance_path: "insurance_file",
        criminal_record_path: "criminal_record_file",
        policy_commitment_path: "policy_commitment_file",
        traffic_law_commitment_path: "traffic_law_commitment_file",
      };
      Object.entries(files).forEach(([path, input]) => {
        if (form.elements[input]?.files?.[0]) snapshot[path] = "selected";
      });
      const status = driverDossierStatus(p, snapshot);
      $("#dossier-progress").value = status.percent;
      $("#dossier-progress-label").textContent = `${status.percent}% completo`;
      $("#dossier-progress-count").textContent = `${status.completed} de ${status.total}`;
      $("#dossier-progress-missing").textContent = status.missing.length
        ? `Faltan ${status.missing.length}: ${status.missing.slice(0, 3).join(", ")}${status.missing.length > 3 ? " y otros requisitos" : ""}.`
        : "Expediente completo. Guarda el avance para enviarlo a Operaciones.";
    };
    form.addEventListener("input", updateProgress);
    form.addEventListener("change", updateProgress);
  }
  if (driver) bindWeeklyProof();
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
function operationsUnitStatus(unit) {
  if (!unit.online) return ["Desconectado", "cancelled"];
  if (!unit.presence_fresh) return ["Señal vencida", "pending"];
  if (unit.trip_id) return [statuses[unit.trip_status] || unit.trip_status, ""];
  return ["Disponible", ""];
}
function startOperationsMap() {
  const element = $("#operations-map");
  if (!element) return;
  const units = S.data.operations_units || [];
  S.map = L.map("operations-map", { zoomControl: true, scrollWheelZoom: true }).setView(
    [28.19065, -105.47045],
    13,
  );
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(S.map);
  S.map.zoomControl.setPosition("bottomright");
  const bounds = [];
  units.forEach((unit) => {
    if (!Number.isFinite(Number(unit.lat)) || !Number.isFinite(Number(unit.lng))) return;
    const point = [Number(unit.lat), Number(unit.lng)];
    const [status] = operationsUnitStatus(unit);
    bounds.push(point);
    const marker = L.marker(point, {
      icon: vehicleIcon(unit.heading, !!unit.trip_id),
      opacity: unit.presence_fresh ? 1 : 0.55,
    })
      .addTo(S.map)
      .bindTooltip(
        `<strong>${e(unit.full_name)}</strong><br>${e(status)} · ${e(unit.plate || "Sin placas")}<br>${unit.trip_id ? `${e(unit.passenger_name || "Pasajero")} · ${money(unit.total_cents || unit.fare_cents)}` : e(unit.vehicle || "Unidad registrada")}`,
        { direction: "top", offset: [0, -18] },
      );
    if (unit.trip_id)
      marker.bindPopup(
        `<strong>${e(unit.full_name)}</strong><p>${e(unit.origin)} → ${e(unit.destination)}</p><a href="#trip/${e(unit.trip_id)}">Abrir viaje y conciliación</a>`,
      );
    const history = Array.isArray(unit.route_history) ? unit.route_history : [];
    if (history.length > 1) {
      const route = history.map((item) => [Number(item.lat), Number(item.lng)]);
      route.forEach((routePoint) => bounds.push(routePoint));
      L.polyline(route, { color: "#ff6a0a", weight: 5, opacity: 0.78 }).addTo(S.map);
    }
  });
  if (bounds.length) S.map.fitBounds(bounds, { padding: [55, 55], maxZoom: 15 });
  setTimeout(() => S.map?.invalidateSize(), 80);
}
async function operationsMapView() {
  const units = S.data.operations_units || [];
  await Promise.all(units.map((unit) => loadAvatar(unit.avatar_path)));
  const live = units.filter((unit) => unit.online && unit.presence_fresh);
  const traveling = live.filter((unit) => unit.trip_id);
  const available = live.filter((unit) => !unit.trip_id);
  const cards = units.length
    ? units
        .map((unit) => {
          const [status, kind] = operationsUnitStatus(unit);
          return `<article class="fleet-unit">${avatar(unit.full_name, unit.avatar_path)}<div><div class="row wrap"><strong>${e(unit.full_name)}</strong><span class="badge ${kind}">${e(status)}</span></div><p>${e([unit.vehicle_color, unit.vehicle_make, unit.vehicle_model, unit.vehicle_year].filter(Boolean).join(" ") || unit.vehicle || "Unidad por completar")} · ${e(unit.plate || "Sin placas")}</p><small>${unit.heartbeat_at ? `Última señal ${date(unit.heartbeat_at)}` : "Sin señal GPS registrada"}</small>${unit.trip_id ? `<a class="link" href="#trip/${e(unit.trip_id)}">${e(unit.passenger_name || "Pasajero")} · ${e(unit.origin)} → ${e(unit.destination)} · ${money(unit.total_cents || unit.fare_cents)}</a>` : ""}</div></article>`;
        })
        .join("")
    : '<div class="empty"><p>Aún no hay unidades registradas.</p></div>';
  shell(
    `<div class="grid4 stats"><div class="stat"><small>Unidades registradas</small><strong>${units.length}</strong><p>Flotilla total</p></div><div class="stat"><small>Con señal activa</small><strong>${live.length}</strong><p>Actualización menor a 90 segundos</p></div><div class="stat"><small>Disponibles</small><strong>${available.length}</strong><p>Listas para asignación</p></div><div class="stat"><small>En servicio</small><strong>${traveling.length}</strong><p>Recorridos visibles en el mapa</p></div></div><div class="operations-map-layout section-gap">${mapFrame("operations-map", "Ubicación y recorrido enviados por el GPS de cada conductor. Una señal mayor a 90 segundos se marca como vencida.")}<section class="panel fleet-list"><div class="row between"><h2>Estado de la flotilla</h2>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div>${cards}</section></div>`,
    "Mapa de operación en vivo",
    "Disponibilidad, ubicación, viaje activo y recorrido GPS de toda la flotilla.",
  );
  startOperationsMap();
}
function adminHome() {
  shell(
    `${stats()}<section class="panel section-gap"><div class="row between"><h2>Operación reciente</h2>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div>${tableTrips()}</section><div class="grid3"><section class="panel"><h2>Mapa de operación</h2><p>${(S.data.operations_units || []).filter((unit) => unit.online && unit.presence_fresh).length} unidades con señal activa. Consulta ubicación y recorridos en tiempo real.</p><a class="btn secondary" href="#opsmap">Abrir mapa en vivo ${I("arrow-right")}</a></section><section class="panel"><h2>Conductores y unidades</h2><p>${S.data.drivers.filter((d) => d.approved).length} aprobados · ${S.data.drivers.filter((d) => !d.approved).length} por revisar</p><a class="btn secondary" href="#fleet">Revisar expedientes ${I("arrow-right")}</a></section><section class="panel"><h2>Control de la operación</h2><p>Viajes, pagos, cuotas y cambios administrativos conservan trazabilidad para conciliación y auditoría.</p><a class="btn secondary" href="#audit">Consultar auditoría ${I("arrow-right")}</a></section></div>`,
    "Tu ciudad, en movimiento.",
    "Viajes, unidades, ingresos y atención en un mismo centro de operación.",
  );
}
function fleet() {
  const cards = S.data.drivers.map((d) => {
    const progress = driverDossierStatus(d, d);
    const doc = (path, label) => path ? `<button class="btn secondary" data-document="${e(path)}">${I("file-check")} ${label}</button>` : "";
    return `<article class="offer dossier-card"><div class="row between"><div><h3>${e(d.full_name)}</h3><p>${e(d.vehicle) || "Unidad pendiente"} · ${e(d.plate) || "Sin placas"}</p></div><span class="badge ${d.approved ? "" : "pending"}">${d.approved ? "Aprobado" : progress.percent === 100 ? "Listo para revisar" : `${progress.percent}% completo`}</span></div><div class="fleet-progress"><progress max="100" value="${progress.percent}">${progress.percent}%</progress><small>${progress.completed} de ${progress.total} requisitos${progress.missing.length ? ` · Faltan: ${e(progress.missing.slice(0, 3).join(", "))}${progress.missing.length > 3 ? "…" : ""}` : " · Expediente completo"}</small></div><div class="meta-row"><span>${e(d.phone)}</span><span>Licencia vence: ${e(d.license_expires || "Sin fecha")}</span><span>Seguro vence: ${e(d.insurance_expires || "Sin fecha")}</span></div><div class="document-row">${d.avatar_path ? `<button class="btn secondary" data-photo="${e(d.avatar_path)}">${I("user-round")} Fotografía</button>` : ""}${doc(d.license_path, "Licencia")}${doc(d.insurance_path, "Seguro")}${doc(d.criminal_record_path, "No antecedentes")}${doc(d.policy_commitment_path, "Políticas Yavoi!")}${doc(d.traffic_law_commitment_path, "Obligaciones viales")}<button class="btn" data-review="${e(d.id)}">Revisar autorización ${I("arrow-right")}</button></div>${d.advertising_interest ? "<small>Interesado en convenios de publicidad</small>" : ""}</article>`;
  }).join("");
  const managedProfiles = (S.data.managed_profiles || []).map((managed) => {
    const editState = profileEditState(managed);
    const status = !editState.locked
      ? '<span class="badge neutral">En captura</span>'
      : editState.authorized
        ? `<span class="badge pending">Edición hasta ${date(managed.profile_edit_allowed_until)}</span>`
        : '<span class="badge">Protegido</span>';
    const accessButton = editState.locked
      ? `<button class="btn ${editState.authorized ? "danger" : "secondary"}" data-profile-edit="${e(managed.id)}" data-allowed="${editState.authorized ? "false" : "true"}">${I(editState.authorized ? "lock-keyhole" : "lock-open")}${editState.authorized ? "Revocar edición" : "Autorizar edición 24 h"}</button>`
      : "";
    return `<article class="managed-profile"><div><strong>${e(managed.full_name || "Perfil sin nombre")}</strong><small>${e(roles[managed.role])} · ${e(managed.phone || "Sin teléfono")} · ${e(managed.id.slice(0, 8))}</small></div>${status}${accessButton}</article>`;
  }).join("");
  shell(
    `<section class="panel"><div class="row between"><div><h2>Expedientes de conductores</h2><p>La aprobación sólo se habilita con los 16 requisitos completos y documentos vigentes.</p></div><a class="link" href="https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf" target="_blank" rel="noopener noreferrer">Ley oficial ${I("external-link")}</a></div>${S.data.drivers.length ? cards : '<div class="empty"><p>Los conductores aparecerán al crear su cuenta y completar el perfil.</p></div>'}</section><section class="panel section-gap"><h2>Control de edición de perfiles</h2><p>Los perfiles completos permanecen protegidos. Una autorización abre una ventana de 24 horas y queda registrada en auditoría.</p><div class="managed-profiles">${managedProfiles || '<div class="empty"><p>No hay perfiles para administrar.</p></div>'}</div></section>`,
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
        const progress = driverDossierStatus(d, d);
        openModal(
          "Revisión de " + d.full_name,
          `<div class="review-readiness ${progress.percent === 100 ? "ready" : ""}"><strong>${progress.percent === 100 ? "Expediente completo" : `Expediente al ${progress.percent}%`}</strong><p>${progress.missing.length ? `Faltan: ${e(progress.missing.join(", "))}.` : "Confirma la legibilidad, autenticidad y vigencia de cada documento antes de aprobar."}</p></div><form id="review"><label>Resultado<select name="approved"><option value="false">Pendiente / no autorizado</option><option value="true" ${d.approved ? "selected" : ""} ${progress.percent < 100 ? "disabled" : ""}>Aprobar conductor</option></select></label><label class="check"><input name="female_verified" type="checkbox" ${d.female_verified ? "checked" : ""}>Identidad de conductora verificada</label><label class="check"><input name="accessible_verified" type="checkbox" ${d.accessible_verified ? "checked" : ""}>Unidad y asistencia de accesibilidad verificadas</label><label>Resultado de la revisión<textarea name="note" required minlength="5" maxlength="1000">${e(d.review_note)}</textarea></label><p class="hint">Confirma documentos, fotografía, vigencias y capacidades. Esta acción queda registrada con tu identidad.</p><button class="btn wide" type="submit">Guardar autorización</button></form>`,
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
  $$("[data-profile-edit]").forEach((item) => {
    item.onclick = () => {
      const allowed = item.dataset.allowed === "true";
      const managed = (S.data.managed_profiles || []).find(
        (profile) => profile.id === item.dataset.profileEdit,
      );
      openModal(
        allowed ? "Autorizar cambio de perfil" : "Revocar autorización",
        `<p>${allowed ? "La persona podrá modificar sus datos durante las próximas 24 horas." : "El perfil volverá inmediatamente al modo protegido."}</p><form id="profile-edit-access"><label>Motivo<textarea name="note" required minlength="5" maxlength="500" placeholder="Describe la verificación realizada y el cambio solicitado."></textarea></label><p class="hint">Perfil: ${e(managed?.full_name || item.dataset.profileEdit)}. Esta acción exige verificación en dos pasos y queda registrada.</p><button class="btn wide" type="submit">${allowed ? "Autorizar por 24 horas" : "Revocar ahora"}</button></form>`,
      );
      bindForm("#profile-edit-access", async (values) => {
        await rpc("authorize_profile_edit", {
          profile_id: item.dataset.profileEdit,
          allowed,
          note: values.note,
        });
        closeModal();
        await refreshPage();
        notify(allowed ? "Edición autorizada por 24 horas." : "Autorización revocada.");
      });
    };
  });
}
function rates() {
  shell(
    `<div class="notice-strip">El estimador considera inicio, recorrido, duración y zona. No cobra reservación. La recogida lejana sólo aplica a una unidad elegida por el pasajero cuando está a más de 7 km. Los cambios afectan nuevas cotizaciones y quedan registrados.</div><div class="grid2">${S.categories.map((c) => `<section class="panel"><h2>Yavoi! ${e(c.name)}</h2><form data-category="${c.id}"><label>Inicio del servicio (MXN)<input name="base" type="number" min="0" max="1000" step="0.01" required value="${c.base_cents / 100}"></label><label>Precio por km estimado (MXN)<input name="km" type="number" min="0" max="100" step="0.01" required value="${c.km_cents / 100}"></label><label>Precio por minuto estimado (MXN)<input name="minute" type="number" min="0" max="100" step="0.01" required value="${c.minute_cents / 100}"></label><label>Tarifa mínima (MXN)<input name="minimum" type="number" min="0" max="1000" step="0.01" required value="${c.minimum_cents / 100}"></label><label>Comisión (%)<input name="commission" type="number" min="0" max="50" step="0.01" required value="${c.commission_bps / 100}"></label><label class="check"><input name="active" type="checkbox" ${c.active ? "checked" : ""}>Categoría disponible</label><button class="btn" type="submit">Guardar tarifa</button></form></section>`).join("")}</div>`,
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
function browserPosition() {
  if (!navigator.geolocation)
    return Promise.reject(
      Error("Tu navegador no permite compartir ubicación. Habilítala para recibir viajes cercanos."),
    );
  return new Promise((resolve, reject) =>
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: true,
      timeout: 15000,
      maximumAge: 10000,
    }),
  ).catch(() => {
    throw Error("No pudimos obtener tu ubicación. Revisa el permiso del navegador e inténtalo de nuevo.");
  });
}
function positionPayload(position) {
  return {
    session_id: S.presenceSession,
    lat: position.coords.latitude,
    lng: position.coords.longitude,
    accuracy: position.coords.accuracy,
    heading: Number.isFinite(position.coords.heading) ? position.coords.heading : null,
    speed: Number.isFinite(position.coords.speed) ? position.coords.speed : null,
  };
}
function driverActiveTrip() {
  return S.data.trips.find(
    (trip) => trip.driver_id === S.user?.id && ["accepted", "arrived", "in_progress"].includes(trip.status),
  );
}
async function sendDriverPosition(position = S.latestPosition) {
  if (!position || !S.driver?.online || S.profile?.role !== "driver" || S.presenceSending) return;
  S.presenceSending = true;
  try {
    const trip = driverActiveTrip();
    await rpc(trip ? "location" : "presence", {
      ...positionPayload(position),
      ...(trip ? { trip_id: trip.id } : {}),
    });
    S.gpsLast = Date.now();
  } finally {
    S.presenceSending = false;
  }
}
function stopDriverTracking() {
  if (S.trackingWatch !== null && navigator.geolocation)
    navigator.geolocation.clearWatch(S.trackingWatch);
  S.trackingWatch = null;
  clearInterval(S.heartbeatTimer);
  S.heartbeatTimer = null;
  S.latestPosition = null;
}
function startDriverTracking() {
  if (
    S.profile?.role !== "driver" ||
    !S.driver?.online ||
    !navigator.geolocation ||
    S.trackingWatch !== null
  )
    return;
  S.trackingWatch = navigator.geolocation.watchPosition(
    (position) => {
      S.latestPosition = position;
      if (Date.now() - S.gpsLast >= 7000)
        sendDriverPosition(position).catch((error) => notify(errorMessage(error)));
    },
    () => notify("La ubicación se pausó. Revisa el permiso del navegador para seguir disponible."),
    { enableHighAccuracy: true, timeout: 20000, maximumAge: 5000 },
  );
  S.heartbeatTimer = setInterval(
    () => sendDriverPosition().catch((error) => notify(errorMessage(error))),
    25000,
  );
}
async function updateDriverPresence(showConfirmation = true) {
  const position = await browserPosition();
  S.latestPosition = position;
  await sendDriverPosition(position);
  if (showConfirmation)
    notify("Ubicación actualizada. Permanecerás activo mientras esta página siga abierta.");
}
async function handleAction(action, b) {
  if (action === "logout") return signOut();
  if (action === "refresh") return run(refreshPage);
  if (action === "map-fullscreen") {
    const panel = b.closest(".map-panel");
    panel?.classList.toggle("fullscreen");
    b.querySelector("span").textContent = panel?.classList.contains("fullscreen") ? "Cerrar" : "Ampliar";
    setTimeout(() => S.map?.invalidateSize(), 80);
    return;
  }
  if (action === "notifications")
    return run(async () => {
      if (!("Notification" in window)) throw Error("Este navegador no admite avisos del sistema.");
      const permission = await Notification.requestPermission();
      if (permission !== "granted")
        throw Error("Los avisos no quedaron autorizados. Puedes activarlos en los permisos del navegador.");
      serviceNotification("Avisos de Yavoi! activados", "Te avisaremos cuando recibas una solicitud dirigida a tu unidad.");
      await renderRoute();
    });
  if (action === "availability")
    return run(async () => {
      const goingOnline = !S.driver.online;
      const position = goingOnline ? await browserPosition() : null;
      try {
        await rpc("availability", { online: goingOnline });
        S.driver.online = goingOnline;
        if (goingOnline) {
          S.latestPosition = position;
          await sendDriverPosition(position);
        } else stopDriverTracking();
        await loadSession();
        notify(
          goingOnline
            ? "Ya estás disponible. Mantén Yavoi! abierto para recibir solicitudes."
            : "Te desconectaste y ya no recibirás nuevas solicitudes.",
        );
      } catch (error) {
        if (goingOnline) {
          await rpc("availability", { online: false }).catch(() => {});
          S.driver.online = false;
          stopDriverTracking();
        }
        throw error;
      }
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
  if (action === "complaint" || action === "trip-report") {
    const selectedTrip = action === "trip-report" ? S.trip?.trip?.id || "" : "";
    openModal(
      selectedTrip ? "Reportar este viaje" : "Cuéntanos qué ocurrió",
      `<form id="complaint"><label>Viaje (opcional)<select name="trip_id"><option value="">Consulta general</option>${S.data.trips.map((t) => `<option value="${e(t.id)}" ${t.id === selectedTrip ? "selected" : ""}>${e(t.id.slice(0, 8))} · ${e(t.destination)}</option>`).join("")}</select></label><label>Motivo<select name="subject"><option>Problema con el viaje</option><option ${selectedTrip ? "selected" : ""}>Seguridad durante el viaje</option><option>Tarifa o efectivo</option><option>Objeto olvidado</option><option>Otro</option></select></label><label>Descripción<textarea name="body" required minlength="10" maxlength="2000" placeholder="Cuéntanos lo ocurrido."></textarea></label><button class="btn wide" type="submit">Enviar reporte</button></form>`,
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
  if (action === "retry-card") {
    const payment = S.trip.payments?.find((item) => item.kind === "ride");
    if (payment) return cardCheckout(payment.id, t.id, payment.amount_cents);
  }
  if (action === "arrive")
    return run(async () => {
      await rpc("transition", { trip_id: t.id, status: "arrived" });
      await tripView(t.id);
    });
  if (action === "finish") {
    openModal(
      t.payment_method === "card" ? "Llegada confirmada" : "Llegada y pago en efectivo",
      `<p>Confirma con el pasajero que llegaron al destino antes de cerrar el viaje.</p><div class="receipt-row"><span>Total</span><strong>${money(t.total_cents || t.fare_cents)}</strong></div>${t.payment_method === "cash" ? `<div class="receipt-row"><span>Paga con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row total"><span>Entrega de cambio</span><strong>${money(changeDue(t.total_cents || t.fare_cents, t.cash_tender_cents))}</strong></div>` : `<div class="hint">Pago con tarjeta confirmado por Mercado Pago.</div>`}<form id="finish">${t.payment_method === "cash" ? '<label class="check"><input name="cash_received" type="checkbox" required>Recibí el pago y entregué el cambio correspondiente.</label>' : '<label class="check"><input type="checkbox" required>Confirmo que el pasajero llegó al destino.</label>'}<button class="btn wide" type="submit">Completar viaje ${I("check")}</button></form>`,
    );
    bindForm("#finish", async () => {
      await rpc("transition", { trip_id: t.id, status: "completed", cash_received: t.payment_method === "cash" });
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
      const cancelled = await rpc("transition", { trip_id: t.id, status: "cancelled", reason: v.reason });
      if (cancelled.refund_payment_id) {
        const { data, error } = await db.functions.invoke("mercado-pago-payment", { body: { action: "refund", payment_id: cancelled.refund_payment_id } });
        if (error || data?.error) notify("El viaje se canceló y el reembolso quedó pendiente para Operaciones.");
      }
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
  if (action === "passenger-tip") {
    if (t.tip_cents > 0) return notify("Este viaje ya incluye una propina. Gracias por reconocer el servicio.");
    openModal(
      "Agradece un gran servicio",
      `<form id="passenger-tip"><label>Importe de propina (MXN)<input name="amount" type="number" min="1" max="1000" step="0.01" required></label><label class="check"><input type="radio" name="payment_method" value="cash" checked>Efectivo entregado directamente</label><label class="check ${S.cardEnabled ? "" : "muted"}"><input type="radio" name="payment_method" value="card" ${S.cardEnabled ? "" : "disabled"}>Tarjeta con Mercado Pago</label><p class="hint">La propina es voluntaria. Una propina en efectivo aparecerá cuando el conductor confirme que la recibió.</p><button class="btn wide" type="submit">Continuar</button></form>`,
    );
    bindForm("#passenger-tip", async (v) => {
      const result = await rpc("post_trip_tip", { trip_id: t.id, amount_cents: cents(v.amount), payment_method: v.payment_method });
      closeModal();
      if (result.payment_id) return cardCheckout(result.payment_id, t.id, result.amount_cents);
      notify("Entrega la propina al conductor; quedará registrada cuando confirme la recepción.");
    });
    return;
  }
  if (action === "receipt") {
    openModal(
      "Comprobante del viaje",
      `<p>Yavoi! · ${e(t.id.slice(0, 8).toUpperCase())}</p><div class="route-line">${e(t.origin)} → ${e(t.destination)}</div><div class="receipt-row"><span>Finalizó</span><span>${date(t.completed_at)}</span></div><div class="receipt-row"><span>Método</span><strong>${t.payment_method === "card" ? "Tarjeta · Mercado Pago" : "Efectivo recibido"}</strong></div><div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${t.tip_cents ? `<div class="receipt-row"><span>Propina</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total</span><strong>${money(t.total_cents || t.fare_cents)}</strong></div><p class="hint">Este comprobante de servicio no es una factura fiscal.</p>`,
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
    const position = await browserPosition();
    S.latestPosition = position;
    await sendDriverPosition(position);
    notify("Ubicación actualizada para el pasajero y Centro de Operaciones.");
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
  } else if (S.view === "opsmap") await operationsMapView();
  else ({ trips: tripsView, profile, wallet, payments: paymentsView, rewards, help, fleet, rates, audit })[S.view]?.();
}
async function refreshPage() {
  const b = await rpc("bootstrap");
  S.profile = b.profile;
  S.driver = b.driver;
  S.categories = b.categories;
  S.cardEnabled = !!b.card_enabled;
  S.mercadoPagoPublicKey = b.mercado_pago_public_key || "";
  S.data = await rpc("dashboard");
  await renderRoute();
}
function startUpdates() {
  clearInterval(pollTimer);
  if (S.channel) db.removeChannel(S.channel);
  S.channel = db
    .channel("yavoi-account-" + S.user.id)
    .on("postgres_changes", { event: "*", schema: "public", table: "trips" }, () => safeRefresh())
    .on(
      "postgres_changes",
      {
        event: "*",
        schema: "public",
        table: "trip_offers",
        filter: `driver_id=eq.${S.user.id}`,
      },
      (payload) => {
        if (S.profile?.role === "driver" && payload.new?.status === "offered")
          serviceNotification(
            "Nueva solicitud de viaje",
            "Abre Yavoi! para revisar al pasajero, el recorrido y el pago antes de responder.",
          );
        safeRefresh();
      },
    )
    .on("postgres_changes", { event: "*", schema: "public", table: "locations" }, () =>
      safeRefresh(),
    )
    .on("postgres_changes", { event: "*", schema: "public", table: "driver_presence" }, () =>
      safeRefresh(),
    )
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "location_history" }, () =>
      safeRefresh(),
    )
    .on("postgres_changes", { event: "*", schema: "public", table: "payments" }, () => safeRefresh())
    .on("postgres_changes", { event: "*", schema: "public", table: "weekly_fees" }, () => safeRefresh())
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
    else if (S.view === "home" && S.profile.role === "passenger") await refreshAvailableUnits();
    else if (
      (S.view === "home" && S.profile.role === "driver") ||
      (S.profile.role === "admin" && ["home", "opsmap", "trips", "payments"].includes(S.view))
    ) {
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
  startDriverTracking();
  sendDriverPosition().catch(() => {});
  safeRefresh();
});
window.addEventListener("offline", () => {
  S.connected = false;
  notify("Sin conexión. Los cambios no se enviarán hasta recuperar la red.");
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    startDriverTracking();
    sendDriverPosition().catch(() => {});
    safeRefresh();
  }
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
if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost")) {
  window.addEventListener("load", () => navigator.serviceWorker.register("/sw.js").catch(() => {}));
}
try {
  try {
    S.socialProviders = await authProviderSettings();
  } catch {}
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
