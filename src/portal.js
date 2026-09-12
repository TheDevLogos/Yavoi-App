import "./portal.css";
import L from "leaflet";
import { createIcons, icons } from "lucide";
import { authProviderSettings, db, rpc } from "./client.js";
import { createGoogleNonce, loadGoogleIdentity, validGoogleClientId } from "./google-auth.js";
import {
  auditActionInfo,
  auditDetailItems,
  buildOperationsPdf,
  imageUrlToDataUrl,
  insuranceStatus,
  periodNames,
  reportNames,
  reportPeriodLabel,
  reportPrintHtml,
} from "./operations-report.js";
import {
  roles,
  statuses,
  navs,
  places,
  DEFAULT_ORIGIN,
  active,
  cents,
  changeDue,
  driverDossierStatus,
  passengerProfileStatus,
  profileEditState,
  PASSENGER_POLICY_VERSION,
  PRIVACY_POLICY_VERSION,
  TERMS_VERSION,
  allowedView,
  normalizeHeading,
  bearingDegrees,
  mfaQrSource,
  serviceAsset,
  rewardEligibleForTrip,
  rewardDiscountCents,
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
const DELICIAS_MAP_CENTER = [DEFAULT_ORIGIN.lat, DEFAULT_ORIGIN.lng];
const OPERATIONS_EMPTY_ZOOM = 13;
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
  tripVehicleMarker: null,
  tripHistoryLine: null,
  tripSuggestedLine: null,
  mapLiveLayer: null,
  opsMarkers: new Map(),
  opsRoutes: new Map(),
  opsHadLiveUnits: null,
  opsListSignature: "",
  opsSearch: {},
  origin: DEFAULT_ORIGIN,
  destination: null,
  pick: null,
  channel: null,
  watch: null,
  gpsLast: 0,
  factor: null,
  authView: "login",
  authError: "",
  socialProviders: { google: false },
  connected: navigator.onLine,
  avatarUrls: {},
  vehiclePhotoUrls: {},
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
  auditReport: null,
  auditFilters: { report: "overview", period: "month", driver_id: "", from: "", to: "" },
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
function serviceNotification(title, body, { tag = "yavoi-update", target = "home" } = {}) {
  notify(`${title}. ${body}`);
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  try {
    const item = new Notification(title, {
      body,
      icon: "/icons/yavoi-192.png",
      badge: "/icons/yavoi-maskable-512.png",
      tag,
      renotify: true,
    });
    item.onclick = () => {
      window.focus();
      location.hash = target;
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
async function loadVehiclePhoto(path) {
  if (!path || S.vehiclePhotoUrls[path]) return;
  const { data, error } = await db.storage.from("yavoi-vehicle-photos").createSignedUrl(path, 300);
  if (!error) S.vehiclePhotoUrls[path] = data.signedUrl;
}
function teardownMap() {
  if (S.map) {
    S.map.remove();
    S.map = null;
  }
  S.markers = [];
  S.tripVehicleMarker = null;
  S.tripHistoryLine = null;
  S.tripSuggestedLine = null;
  S.mapLiveLayer = null;
  S.opsMarkers.clear();
  S.opsRoutes.clear();
  S.opsListSignature = "";
  S.opsHadLiveUnits = null;
  S.roadRoute = null;
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
  S.auditReport = null;
  S.avatarUrls = {};
  S.vehiclePhotoUrls = {};
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
  S.auditReport = null;
  await renderRoute();
  startUpdates();
  if (S.profile.role === "driver" && S.driver?.online) startDriverTracking();
  else stopDriverTracking();
  setTimeout(maybeShowEngagementPromo, 450);
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
    `<div class="app-shell role-${e(p.role)}"><aside class="sidebar"><a href="/"><img class="logo" src="/assets/yavoi-logo.png" alt="Yavoi!"></a><div class="city">${I("map-pin")} Delicias, Chihuahua</div><div class="nav-label">${e(roles[p.role]).toUpperCase()}</div><nav>${navs[p.role].map(([id, icon, label]) => `<a href="#${id}" class="${S.view === id ? "active" : ""}">${I(icon)}<span>${label}</span></a>`).join("")}</nav><div class="sidebar-bottom"><a class="sidebar-user" href="#profile">${avatar(p.full_name, p.avatar_path)}<div><strong>${e(p.full_name)}</strong><small>${e(roles[p.role])}</small></div></a><button class="logout" data-action="logout">${I("log-out")}<span>Cerrar sesión</span></button></div></aside><div class="workspace"><header class="topbar"><div class="topbar-brand"><img class="mobile-brand" src="/assets/yavoi-logo.png" alt="Yavoi!"><strong>Mi Yavoi! <span class="muted">/ ${e(roles[p.role])}</span></strong></div><div class="right"><span class="connection ${S.connected ? "" : "offline"}"><i></i>${S.connected ? "Conectado" : "Sin conexión"}</span><a class="landing-link link" href="/">Ir a la landing</a>${p.role === "admin" ? `<a class="icon-btn" href="#help" aria-label="Reportes y atención">${I("headset")}</a>` : ""}<a class="icon-btn" href="#profile" aria-label="Mi perfil">${I("user-round")}</a></div></header><main><div class="page-title"><div><div class="eyebrow">${p.role === "admin" ? "CENTRO DE OPERACIÓN" : "TU CIUDAD. A TU RITMO."}</div><h1>${title}</h1><p>${subtitle}</p></div><span class="badge neutral">${I("shield-check")} Acceso personal</span></div><div id="page-content">${content}</div></main><div class="footer-note">Yavoi! · Tu raite, al instante · Delicias, Chihuahua</div></div></div>`;
  if (p.role === "admin") enhanceOperationsLayout();
  iconsNow();
  $$("[data-action]").forEach((b) => (b.onclick = () => handleAction(b.dataset.action, b)));
}
function operationsSectionState() {
  try { return JSON.parse(localStorage.getItem(`yavoi:operations:${S.view}:sections`) || "{}"); }
  catch { return {}; }
}
function saveOperationsSectionState() {
  const state = {};
  $$("#page-content .ops-section").forEach((section) => { state[section.dataset.sectionKey] = section.open; });
  try { localStorage.setItem(`yavoi:operations:${S.view}:sections`, JSON.stringify(state)); } catch {}
}
function applyOperationsSearch(value = S.opsSearch[S.view]) {
  const query = String(value || "").trim().toLowerCase();
  S.opsSearch[S.view] = query;
  let visible = 0;
  const items = $$("#page-content tbody tr, #page-content .dossier-card, #page-content .fee-card, #page-content .campaign-card, #page-content .marketing-reward, #page-content .audit-item, #operations-unit-list .fleet-unit");
  items.forEach((item) => {
    const show = !query || item.textContent.toLowerCase().includes(query);
    item.classList.toggle("ops-filtered", !show);
    if (show) {
      visible += 1;
      if (query && item.matches("details")) item.open = true;
      if (query) {
        const section = item.closest("details.ops-section");
        if (section) section.open = true;
      }
    }
  });
  const empty = $("#ops-filter-empty");
  if (empty) empty.classList.toggle("hidden", !query || visible > 0 || !items.length);
}
function enhanceOperationsLayout() {
  const root = $("#page-content");
  if (!root) return;
  root.classList.add("operations-surface");
  const toolbar = document.createElement("div");
  toolbar.className = "operations-layout-tools";
  toolbar.innerHTML = `<label>${I("search")}<input id="ops-quick-search" type="search" value="${e(S.opsSearch[S.view] || "")}" placeholder="Filtrar información visible" aria-label="Filtrar información visible"></label><div><button class="btn secondary" type="button" data-ops-layout="open">${I("unfold-vertical")} Expandir</button><button class="btn secondary" type="button" data-ops-layout="close">${I("fold-vertical")} Colapsar</button></div>`;
  root.prepend(toolbar);
  const stored = operationsSectionState();
  const excluded = ".fleet-list,.trip-panel,.trip-chat-panel,.report-loading";
  $$("section.panel", root).filter((panel) => !panel.matches(excluded) && !panel.closest("details.ops-section") && !panel.closest("dialog")).forEach((panel, index) => {
    const heading = panel.querySelector(":scope > h2, :scope > .row h2, :scope > .row > div h2");
    if (!heading) return;
    const key = `${index}-${heading.textContent.trim().toLowerCase().replace(/[^a-z0-9áéíóúñ]+/gi, "-")}`;
    const section = document.createElement("details");
    section.className = "ops-section";
    section.dataset.sectionKey = key;
    section.open = stored[key] ?? index === 0;
    const summary = document.createElement("summary");
    summary.innerHTML = `<span>${I("layout-panel-top")}<strong>${e(heading.textContent.trim())}</strong></span><span class="ops-section-state">${section.open ? "Visible" : "Colapsado"}</span>${I("chevron-down")}`;
    panel.before(section);
    section.append(summary, panel);
    heading.classList.add("ops-original-heading");
    section.addEventListener("toggle", () => {
      const label = $(".ops-section-state", section);
      if (label) label.textContent = section.open ? "Visible" : "Colapsado";
      saveOperationsSectionState();
    });
  });
  const search = $("#ops-quick-search");
  search.oninput = () => applyOperationsSearch(search.value);
  $$('[data-ops-layout]').forEach((item) => item.onclick = () => {
    $$("#page-content .ops-section").forEach((section) => { section.open = item.dataset.opsLayout === "open"; });
    saveOperationsSectionState();
  });
  root.insertAdjacentHTML("beforeend", '<p class="hint hidden" id="ops-filter-empty">No hay información que coincida con este filtro.</p>');
  applyOperationsSearch();
}
function mapFrame(
  id = "ride-map",
  caption = "Busca una dirección con calle y número, o elige qué marcador colocar en el mapa.",
) {
  return `<section class="map-panel"><div class="map-top">Delicias, Chihuahua</div><div class="map-placement hidden" id="${id}-placement">${I("crosshair")}<span></span><button type="button" data-action="cancel-map-placement" aria-label="Cancelar selección">${I("x")}</button></div><button class="map-fullscreen" type="button" data-action="map-fullscreen" aria-label="Ver mapa en pantalla completa">${I("maximize-2")}<span>Ampliar</span></button><div class="map" id="${id}" aria-label="Mapa de Delicias"></div><div class="map-caption">${I("shield-check")}<span>${caption}</span></div></section>`;
}
async function mapService(body) {
  const { data, error } = await db.functions.invoke("maps", { body });
  if (error) throw new Error(data?.error || error.message);
  if (data?.error) throw new Error(data.error);
  return data;
}
function setMapPicker(kind = null) {
  S.pick = kind;
  const map = $("#ride-map");
  const banner = $("#ride-map-placement");
  map?.classList.toggle("placing-point", Boolean(kind));
  banner?.classList.toggle("hidden", !kind);
  const label = banner?.querySelector("span");
  if (label) label.textContent = kind === "origin" ? "Toca el mapa para colocar el punto de partida" : "Toca el mapa para colocar el destino";
  $("#map-origin")?.classList.toggle("active", kind === "origin");
  $("#map-destination")?.classList.toggle("active", kind === "destination");
}
async function placeRidePoint(kind, point, { resolveAddress = false, focus = false } = {}) {
  if (!kind || !Number.isFinite(Number(point.lat)) || !Number.isFinite(Number(point.lng))) return;
  const chosen = {
    name: point.name || `Punto en mapa (${Number(point.lat).toFixed(5)}, ${Number(point.lng).toFixed(5)})`,
    lat: Number(point.lat),
    lng: Number(point.lng),
  };
  S[kind] = chosen;
  const input = $(`[name=${kind}]`);
  if (input) input.value = chosen.name;
  setMapPicker();
  S.roadRoute = null;
  drawPoints(null, { fit: false });
  if (focus) S.map?.setView([chosen.lat, chosen.lng], 17);
  if (resolveAddress) {
    try {
      const resolved = await mapService({ type: "reverse", lat: chosen.lat, lng: chosen.lng });
      if (S[kind]?.lat === chosen.lat && S[kind]?.lng === chosen.lng && resolved?.name) {
        S[kind].name = resolved.name;
        if (input) input.value = resolved.name;
        drawPoints(null, { fit: false });
      }
    } catch {}
  }
  await loadRoadRoute();
  if (kind === "origin") await refreshAvailableUnits();
  scheduleRideDraft();
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
        ? `<p class="address-search-help">Elige el resultado correcto. “Dirección exacta” indica que el número está registrado en el mapa.</p><div class="address-results">${result.results.map((place, index) => `<button type="button" data-place="${index}">${I("map-pin")}<span><strong>${e(place.name)}</strong><small>${place.precision === "exact" ? "Dirección exacta" : place.precision === "street" ? "Calle localizada; confirma el punto en el mapa" : "Lugar localizado"}${place.details && place.details !== place.name ? ` · ${e(place.details)}` : ""}</small></span></button>`).join("")}</div>`
        : `<div class="empty">${I("map-pin-off")}<p>No encontramos esa dirección. Revisa calle, número y colonia, o colócala directamente en el mapa.</p><button class="btn" type="button" data-place-on-map="${e(kind)}">Colocar ${kind === "origin" ? "origen" : "destino"} en el mapa ${I("crosshair")}</button></div>`,
    );
    $$('[data-place]', modal).forEach((item) => {
      item.onclick = async () => {
        const place = result.results[Number(item.dataset.place)];
        closeModal();
        await placeRidePoint(kind, place, { focus: true });
      };
    });
    $('[data-place-on-map]', modal)?.addEventListener("click", () => {
      closeModal();
      setMapPicker(kind);
      notify(`Toca el mapa para colocar ${kind === "origin" ? "el punto de partida" : "el destino"}.`);
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
    renderRouteGuide();
    updateRouteMonitor();
  } catch (error) {
    if (version === S.routeVersion) notify("No pudimos trazar la ruta vial; puedes continuar con la estimación operativa.");
  }
}
function routeStepText(step = {}) {
  const street = String(step.street || "").trim();
  const road = street ? ` por ${street}` : "";
  const modifier = {
    left: "a la izquierda",
    "slight left": "ligeramente a la izquierda",
    "sharp left": "pronunciadamente a la izquierda",
    right: "a la derecha",
    "slight right": "ligeramente a la derecha",
    "sharp right": "pronunciadamente a la derecha",
    uturn: "en retorno",
    straight: "de frente",
  }[step.modifier] || "de frente";
  if (step.type === "depart") return `Inicia${road}`;
  if (step.type === "arrive") return "Llegaste al destino";
  if (["roundabout", "rotary", "roundabout turn"].includes(step.type)) return `En la glorieta continúa ${modifier}${road}`;
  if (step.type === "merge") return `Incorpórate ${modifier}${road}`;
  if (step.type === "fork") return `Mantente ${modifier}${road}`;
  if (step.type === "new name" || step.type === "continue") return `Continúa${road}`;
  return `Gira ${modifier}${road}`;
}
function routeDistance(value) {
  const meters = Math.max(0, Number(value) || 0);
  return meters < 1000 ? `${Math.round(meters)} m` : `${decimal(meters / 1000)} km`;
}
function routeGuideMarkup(route = S.roadRoute) {
  const steps = Array.isArray(route?.instructions) ? route.instructions : [];
  if (!steps.length) return '<p class="muted">Calculando indicaciones por calles…</p>';
  return `<div class="route-guide-summary"><span>${I("route")}<strong>${decimal(route.distance_km)} km</strong></span><span>${I("clock-3")}<strong>${Number(route.duration_minutes)} min</strong></span></div><ol>${steps.map((step) => `<li><span>${I(step.type === "arrive" ? "flag" : step.type === "depart" ? "navigation" : "corner-down-right")}</span><div><strong>${e(routeStepText(step))}</strong><small>${routeDistance(step.distance_m)}</small></div></li>`).join("")}</ol>`;
}
function renderRouteGuide() {
  const guide = $("#route-guide-content");
  if (!guide) return;
  guide.innerHTML = routeGuideMarkup();
  iconsNow();
}
function distanceToRouteMeters(location, coordinates = S.roadRoute?.coordinates || []) {
  if (!location || coordinates.length < 2) return null;
  const latitude = (Number(location.lat) * Math.PI) / 180;
  const metersPerLng = 111320 * Math.cos(latitude);
  const metersPerLat = 110540;
  let nearest = Infinity;
  for (let index = 1; index < coordinates.length; index += 1) {
    const [lngA, latA] = coordinates[index - 1].map(Number);
    const [lngB, latB] = coordinates[index].map(Number);
    const ax = (lngA - Number(location.lng)) * metersPerLng;
    const ay = (latA - Number(location.lat)) * metersPerLat;
    const bx = (lngB - Number(location.lng)) * metersPerLng;
    const by = (latB - Number(location.lat)) * metersPerLat;
    const dx = bx - ax;
    const dy = by - ay;
    const lengthSquared = dx * dx + dy * dy;
    const progress = lengthSquared ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / lengthSquared)) : 0;
    nearest = Math.min(nearest, Math.hypot(ax + progress * dx, ay + progress * dy));
  }
  return Number.isFinite(nearest) ? nearest : null;
}
function routeMonitorMarkup() {
  const t = S.trip?.trip;
  if (!t || S.profile?.role !== "passenger" || t.status !== "in_progress") return "";
  const location = S.trip?.location;
  const stale = !location || Date.now() - Date.parse(location.updated_at) > 60000;
  if (stale)
    return `<section class="route-monitor pending">${I("satellite")}<div><strong>Esperando una señal GPS reciente</strong><p>Conservamos el último recorrido recibido y lo actualizaremos al recuperar la señal.</p></div></section>`;
  const rawDistance = distanceToRouteMeters(location);
  if (rawDistance === null)
    return `<section class="route-monitor pending">${I("route")}<div><strong>Comparando el recorrido</strong><p>Estamos cargando la ruta sugerida por calles.</p></div></section>`;
  const distance = Math.max(0, rawDistance - Math.max(0, Number(location.accuracy) || 0));
  const pronounced = distance > 350;
  const attention = distance > 180;
  return `<section class="route-monitor ${pronounced ? "deviation" : attention ? "attention" : "aligned"}">${I(pronounced ? "triangle-alert" : attention ? "route-off" : "shield-check")}<div><strong>${pronounced ? "Desviación pronunciada detectada" : attention ? "La unidad se alejó de la ruta sugerida" : "Recorrido cercano a la ruta sugerida"}</strong><p>${pronounced || attention ? `La ubicación está aproximadamente a ${Math.round(distance)} m del trazo. Puede deberse a tráfico, cierres o una mejor entrada.` : "La posición recibida coincide con el trayecto recomendado, dentro del margen de precisión del GPS."}</p>${pronounced || attention ? '<button class="link" type="button" id="ask-route">Preguntar al conductor por el chat</button>' : ""}</div></section>`;
}
function updateRouteMonitor() {
  const container = $("#route-monitor");
  if (!container) return;
  container.innerHTML = routeMonitorMarkup();
  iconsNow();
  $("#ask-route")?.addEventListener("click", () => {
    const input = $('#chat-form input[name="body"]');
    if (!input) return;
    input.value = "Hola, noto una diferencia con la ruta sugerida. ¿Todo está bien con el recorrido?";
    input.scrollIntoView({ behavior: "smooth", block: "center" });
    input.focus();
  });
}
function googleNavigationUrl(trip) {
  const pickup = ["accepted", "arrived"].includes(trip.status);
  const lat = Number(pickup ? trip.origin_lat : trip.dest_lat);
  const lng = Number(pickup ? trip.origin_lng : trip.dest_lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return "";
  const params = new URLSearchParams({ api: "1", destination: `${lat},${lng}`, travelmode: "driving", dir_action: "navigate" });
  return `https://www.google.com/maps/dir/?${params}`;
}
async function refreshAvailableUnits({ fit = true } = {}) {
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
    const selectionLabel = $("#unit-selection");
    if (selectionLabel && !S.selectedUnit) selectionLabel.textContent = "Asignación automática a la unidad más cercana";
    const label = $("#unit-status");
    const serviceName = S.categories.find((item) => item.id === category)?.name || category;
    const radius = Number(S.units[0]?.search_radius_km || 0);
    if (label) label.textContent = S.units.length
      ? `${S.units.length} unidad${S.units.length === 1 ? "" : "es"} Yavoi! ${serviceName} dentro de ${radius} km. Sólo mostramos el tipo de servicio antes de confirmar.`
      : "No hay unidades compatibles conectadas en este momento. Puedes cotizar y esperar disponibilidad.";
    drawPoints(null, { fit });
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
const mapVehicleAsset = (category) => `/assets/map-vehicles/${["basic", "large", "plus", "commercial", "pickup"].includes(category) ? category : "basic"}.svg`;
const vehicleIcon = (heading = 0, selected = false, category = "basic") => {
  const angle = normalizeHeading(heading) ?? 0;
  const safeCategory = ["basic", "large", "plus", "commercial", "pickup"].includes(category) ? category : "basic";
  return L.divIcon({
    className: `vehicle-icon-wrap vehicle-${safeCategory}`,
    html: `<div class="vehicle-icon ${selected ? "selected" : ""}"><img src="${mapVehicleAsset(safeCategory)}" alt="" data-vehicle-category="${safeCategory}" style="transform:rotate(${angle}deg)"></div>`,
    iconSize: [48, 64],
    iconAnchor: [24, 32],
  });
};
function vehicleScaleForZoom(zoom) {
  const safeZoom = Number.isFinite(Number(zoom)) ? Number(zoom) : 14;
  return Math.min(1, Math.max(0.42, 0.42 + (safeZoom - 10) * 0.095));
}
function syncVehicleScale() {
  if (!S.map) return;
  S.map.getContainer().style.setProperty("--vehicle-marker-scale", vehicleScaleForZoom(S.map.getZoom()));
}
function bindVehicleScale() {
  syncVehicleScale();
  S.map?.on("zoomend", syncVehicleScale);
}
function vehicleHeading(marker, reportedHeading, point) {
  const reported = normalizeHeading(reportedHeading);
  if (reported !== null) return reported;
  const current = marker?.getLatLng();
  const moved = current && S.map?.distance(current, point) >= 3
    ? bearingDegrees({ lat: current.lat, lng: current.lng }, { lat: point[0], lng: point[1] })
    : null;
  return moved ?? marker?._yavoiHeading ?? 0;
}
function rotateVehicle(marker, heading) {
  marker._yavoiHeading = heading;
  const image = marker.getElement()?.querySelector("img");
  if (image) image.style.transform = `rotate(${heading}deg)`;
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
  bindVehicleScale();
  if (!trip)
    S.map.on("click", async (ev) => {
      if (!S.pick) return;
      const kind = S.pick;
      await placeRidePoint(kind, ev.latlng, { resolveAddress: true });
    });
  drawPoints(trip);
  loadRoadRoute(trip);
  setTimeout(() => S.map?.invalidateSize(), 70);
}
function drawPoints(t = null, { fit = true } = {}) {
  if (!S.map) return;
  S.markers.forEach((m) => m.remove());
  S.markers = [];
  S.tripVehicleMarker = null;
  S.tripHistoryLine = null;
  S.tripSuggestedLine = null;
  const points = t
    ? [
        { lat: t.origin_lat, lng: t.origin_lng },
        { lat: t.dest_lat, lng: t.dest_lng },
      ]
    : [S.origin, S.destination];
  points.forEach((p, i) => {
    if (p) {
      const kind = i === 1 ? "destination" : "origin";
      const marker = L.marker([p.lat, p.lng], { icon: pointIcon(i === 1), zIndexOffset: 1200, draggable: !t })
        .bindTooltip(i ? "Destino · arrastra para ajustar" : "Punto de partida · arrastra para ajustar", { direction: "top" })
        .addTo(S.map);
      if (!t) marker.on("dragend", (event) => placeRidePoint(kind, event.target.getLatLng(), { resolveAddress: true }));
      S.markers.push(marker);
    }
  });
  if (points.every(Boolean)) {
    const suggestedLine = L.polyline(
        S.roadRoute?.coordinates?.length
          ? S.roadRoute.coordinates.map(([lng, lat]) => [lat, lng])
          : points.map((p) => [p.lat, p.lng]),
        { color: "#183c54", weight: 5, opacity: 0.72, dashArray: t ? "10 8" : null },
      ).addTo(S.map);
    if (t) S.tripSuggestedLine = suggestedLine;
    S.markers.push(suggestedLine);
  }
  if (!t) {
    const requestedCategory = $('[name=category]:checked')?.value || "basic";
    const serviceName = S.categories.find((item) => item.id === requestedCategory)?.name || requestedCategory;
    S.units.forEach((unit, index) => {
      const marker = L.marker([unit.lat, unit.lng], { icon: vehicleIcon(0, S.selectedUnit === unit.unit_id, unit.category || requestedCategory) })
        .bindTooltip(`Yavoi! ${e(serviceName)} · ${index === 0 ? "Unidad más cercana" : "Unidad disponible"}`)
        .on("click", () => {
          S.selectedUnit = S.selectedUnit === unit.unit_id ? null : unit.unit_id;
          drawPoints(null, { fit: false });
          const label = $("#unit-selection");
          if (label) label.textContent = S.selectedUnit
            ? `Yavoi! ${serviceName} · ${index === 0 ? "Unidad más cercana seleccionada" : "Unidad seleccionada"}`
            : "Asignación automática a la unidad más cercana";
        })
        .addTo(S.map);
      S.markers.push(marker);
    });
  }
  if (t && S.trip?.route_history?.length > 1) {
    S.tripHistoryLine = L.polyline(S.trip.route_history.map((point) => [point.lat, point.lng]), { color: "#ff6a0a", weight: 6, opacity: 0.9 }).addTo(S.map);
    S.markers.push(S.tripHistoryLine);
  }
  if (t && S.trip?.location) {
    const loc = S.trip.location;
    const stale = Date.now() - Date.parse(loc.updated_at) > 60000;
    const heading = normalizeHeading(loc.heading) ?? 0;
    S.tripVehicleMarker = L.marker([loc.lat, loc.lng], { icon: vehicleIcon(heading, false, t.category), opacity: stale ? 0.55 : 1 })
      .bindTooltip(stale ? "Última posición; señal desactualizada" : "Posición del conductor")
      .addTo(S.map);
    S.tripVehicleMarker._yavoiHeading = heading;
    S.markers.push(S.tripVehicleMarker);
  }
  if (fit) {
    const visiblePoints = points.filter(Boolean).map((point) => [point.lat, point.lng]);
    if (!t) S.units.forEach((unit) => visiblePoints.push([Number(unit.lat), Number(unit.lng)]));
    if (visiblePoints.length > 1) S.map.fitBounds(visiblePoints, { padding: [55, 55], maxZoom: 15 });
  }
}
function updateTripMap() {
  if (!S.map || !S.trip) return;
  const history = Array.isArray(S.trip.route_history) ? S.trip.route_history : [];
  const route = history.map((point) => [Number(point.lat), Number(point.lng)]);
  if (route.length > 1) {
    if (S.tripHistoryLine) S.tripHistoryLine.setLatLngs(route);
    else {
      S.tripHistoryLine = L.polyline(route, { color: "#ff6a0a", weight: 6, opacity: 0.9 }).addTo(S.map);
      S.markers.push(S.tripHistoryLine);
    }
  }
  const loc = S.trip.location;
  if (!loc || !Number.isFinite(Number(loc.lat)) || !Number.isFinite(Number(loc.lng))) return;
  const stale = Date.now() - Date.parse(loc.updated_at) > 60000;
  const point = [Number(loc.lat), Number(loc.lng)];
  const heading = vehicleHeading(S.tripVehicleMarker, loc.heading, point);
  if (!S.tripVehicleMarker) {
    S.tripVehicleMarker = L.marker(point, { icon: vehicleIcon(heading, false, S.trip.trip?.category), opacity: stale ? 0.55 : 1 })
      .bindTooltip(stale ? "Última posición; señal desactualizada" : "Posición del conductor")
      .addTo(S.map);
    S.tripVehicleMarker._yavoiHeading = heading;
    S.markers.push(S.tripVehicleMarker);
    return;
  }
  if (!stale) S.tripVehicleMarker.setLatLng(point);
  S.tripVehicleMarker
    .setOpacity(stale ? 0.55 : 1)
    .setTooltipContent(stale ? "Última posición; señal desactualizada" : "Posición del conductor");
  if (!stale) rotateVehicle(S.tripVehicleMarker, heading);
  updateRouteMonitor();
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
      `<section class="panel profile-required"><div class="profile-head"><div class="profile-lock">${I("shield-check")}</div><div><div class="eyebrow">SEGURIDAD ANTES DEL PRIMER VIAJE</div><h2>Completa tu perfil de pasajero</h2><p>Necesitamos tus datos de contacto, fotografía, contacto de emergencia y aceptación de seguridad, privacidad y términos de servicio.</p></div></div><div class="dossier-progress"><div class="row between"><strong>${passengerProgress.percent}% completo</strong><b>${passengerProgress.completed} de ${passengerProgress.total}</b></div><progress max="100" value="${passengerProgress.percent}">${passengerProgress.percent}%</progress><p>Falta: ${e(passengerProgress.missing.join(", "))}.</p></div><a class="btn" href="#profile">Completar mi perfil ${I("arrow-right")}</a></section>`,
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
    `<div class="booking"><section class="panel"><div class="row between"><h2>Planea tu viaje</h2><small id="draft-state">${draft ? "Plan recuperado" : "Guardado automático"}</small></div><form id="quote-form"><div class="address-field"><label class="input-point">Punto de partida${I("circle-dot")}<input name="origin" value="${e(S.origin?.name || draft?.origin || "")}" required maxlength="200" autocomplete="street-address" placeholder="Ej. Av. Río Conchos 123"></label><button type="button" data-search-address="origin" aria-label="Buscar punto de partida">${I("search")}<span>Buscar</span></button></div><div class="address-field"><label class="input-point">Destino${I("map-pin")}<input name="destination" list="destinations" value="${e(S.destination?.name || draft?.destination || "")}" placeholder="Ej. Calle 3a Norte 120, colonia Centro" required maxlength="200" autocomplete="street-address"></label><button type="button" data-search-address="destination" aria-label="Buscar destino">${I("search")}<span>Buscar</span></button></div><datalist id="destinations">${places.map((place) => `<option value="${e(place.name)}">`).join("")}</datalist><div class="origin-tools"><button type="button" id="gps-origin">${I("locate-fixed")} Mi ubicación</button><button type="button" id="map-origin"><img src="/assets/map-origin.svg" alt=""> Elegir origen en mapa</button><button type="button" id="map-destination"><img src="/assets/map-destination.svg" alt=""> Elegir destino en mapa</button></div><h3>Elige cómo moverte</h3><div class="category-grid">${cats.map((category) => `<label class="category-option"><div class="car"><img src="${serviceAsset(category.id)}" alt=""></div><div><strong>Yavoi! ${e(category.name)}</strong><small>${category.seats} plazas · ${money(category.km_cents)}/km estimado</small></div><span class="rate">Desde ${money(category.minimum_cents)}</span><input type="radio" name="category" value="${e(category.id)}" ${category.id === selectedCategory ? "checked" : ""} required></label>`).join("")}</div><div class="grid2 service-request"><label>Personas que viajarán<input name="party_size" type="number" min="1" max="8" step="1" required value="${e(draft?.party_size || 1)}"></label><label>Indicaciones para el conductor<textarea name="service_notes" maxlength="500" placeholder="Ejemplo: requiero espacio para mesas y equipo">${e(draft?.service_notes || "")}</textarea></label></div><label class="check women">${I("shield-check")}<span>Prefiero una conductora<small>Sujeto a disponibilidad de conductoras conectadas.</small></span><input name="women_only" type="checkbox" ${draft?.women_only ? "checked" : ""}></label><label class="check accessible-service">${I("accessibility")}<span>Servicio para personas con alguna discapacidad</span><input name="accessible" type="checkbox" ${draft?.accessible ? "checked" : ""}></label><div class="unit-summary"><img class="unit-map-car" src="/assets/map-car-top.svg" alt=""> <div><strong id="unit-selection">Asignación automática a la unidad más cercana</strong><small id="unit-status">Consultando unidades disponibles…</small></div></div><label>Programar (opcional)<input name="scheduled_at" type="datetime-local" value="${e(draft?.scheduled_at || "")}"></label><button class="btn wide" type="submit">Ver tarifa y método de pago ${I("arrow-right")}</button><p class="hint">La búsqueda comienza en 1 km y se amplía de kilómetro en kilómetro hasta encontrar unidades compatibles. Antes de confirmar sólo verás el tipo de servicio y su ubicación aproximada. Cuando un conductor acepte, recibirás su nombre, fotografía, vehículo, color, modelo, placas y calificación.</p></form></section>${mapFrame()}</div>`,
    `¿A dónde vamos, ${e(S.profile.full_name.split(" ")[0])}?`,
    "Elige tu destino, necesidades y revisa el precio antes de confirmar.",
  );
  startMap();
  refreshAvailableUnits();
  $$('[data-search-address]').forEach((search) => search.onclick = () => searchAddress(search.dataset.searchAddress));
  ["origin", "destination"].forEach((kind) => {
    $(`[name=${kind}]`).addEventListener("keydown", (event) => {
      if (event.key !== "Enter") return;
      event.preventDefault();
      searchAddress(kind);
    });
  });
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
        notify("Pulsa Buscar para localizar la dirección, o elige el marcador en el mapa.");
      }
      scheduleRideDraft();
    }),
  );
  $("#map-origin").onclick = () => {
    setMapPicker(S.pick === "origin" ? null : "origin");
  };
  $("#map-destination").onclick = () => {
    setMapPicker(S.pick === "destination" ? null : "destination");
  };
  $("#gps-origin").onclick = () => {
    if (!navigator.geolocation) return notify("Tu navegador no permite ubicación. Usa el mapa.");
    navigator.geolocation.getCurrentPosition(
      (position) => placeRidePoint("origin", {
        name: "Mi ubicación",
        lat: position.coords.latitude,
        lng: position.coords.longitude,
      }, { resolveAddress: true, focus: true }),
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
  const tripRewards = (S.data.marketing?.rewards_enabled === false ? [] : S.data.reward_wallet?.redemptions || []).filter(
    (reward) => reward.status === "available" && rewardEligibleForTrip(reward, q),
  );
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
  const rewardOptions = tripRewards.length
    ? `<label>Aplicar recompensa<select name="reward_code"><option value="">No aplicar en este viaje</option>${tripRewards.map((reward) => `<option value="${e(reward.code)}">${e(reward.name)} · ${e(reward.code)}</option>`).join("")}</select></label>`
    : `<p class="hint">Aún no tienes recompensas disponibles para aplicar a este viaje. Puedes conseguirlas en Puntos Viajeros.</p>`;
  openModal(
    "Tu viaje, con todo claro",
    `<div class="route-line">${I("circle-dot")}${e(q.origin)}</div><div class="route-line destination">${I("map-pin")}${e(q.destination)}</div><div class="estimate-grid"><div><small>Conductor a recogerte</small><strong>${decimal(q.pickup_distance_km)} km · ${q.pickup_eta_minutes} min</strong><span>${pickupBasis}</span></div><div><small>Tu recorrido</small><strong>${decimal(q.distance_km)} km · ${q.trip_eta_minutes} min</strong><span>${zoneLabel(q.service_zone)}</span></div></div><p class="hint">El precio usa la distancia y duración estimadas por el servidor. Puede variar en una nueva cotización por tráfico, cierre de calles o disponibilidad. ${q.scheduled_at ? "Programado: " + date(q.scheduled_at) : ""}</p><div class="fare-breakdown"><div class="receipt-row"><span>Inicio del servicio</span><span>${money(category?.base_cents)}</span></div><div class="receipt-row"><span>Distancia · ${decimal(q.distance_km)} km</span><span>${money(q.distance_charge_cents)}</span></div><div class="receipt-row"><span>Tiempo estimado · ${q.trip_eta_minutes} min</span><span>${money(q.time_charge_cents)}</span></div>${q.minimum_adjustment_cents ? `<div class="receipt-row"><span>Ajuste a tarifa mínima</span><span>${money(q.minimum_adjustment_cents)}</span></div>` : ""}${q.pickup_surcharge_cents ? `<div class="receipt-row"><span>Unidad elegida a más de 7 km · sólo excedente</span><span>${money(q.pickup_surcharge_cents)}</span></div>` : ""}${q.zone_surcharge_cents ? `<div class="receipt-row"><span>Ajuste por ${zoneLabel(q.service_zone).toLowerCase()}</span><span>${money(q.zone_surcharge_cents)}</span></div>` : ""}${q.accessibility_surcharge_cents ? `<div class="receipt-row"><span>Servicio para personas con alguna discapacidad</span><span>${money(q.accessibility_surcharge_cents)}</span></div>` : ""}<div class="receipt-row reward-discount-row hidden"><span id="reward-preview-name">Recompensa</span><strong id="reward-preview-value">-$0.00</strong></div><div class="receipt-row"><span>Propina voluntaria</span><strong id="tip-preview">$0.00</strong></div><div class="receipt-row total"><span>Total</span><strong id="total-preview">${money(q.fare_cents)}</strong></div></div><form id="payment"><h3>Tu recompensa</h3>${rewardOptions}<h3>Agrega una propina (opcional)</h3><div class="tip-options"><label><input type="radio" name="tip" value="0" checked>Sin propina</label><label><input type="radio" name="tip" value="10">10%</label><label><input type="radio" name="tip" value="15">15%</label><label><input type="radio" name="tip" value="custom">Otro</label></div><label id="custom-tip-label" class="hidden">Propina (MXN)<input name="custom_tip" type="number" min="1" max="1000" step="0.01"></label><h3>¿Cómo quieres pagar?</h3><label class="check"><input type="radio" name="payment_method" value="cash" checked>Efectivo al finalizar el viaje</label><label class="check ${S.cardEnabled ? "" : "muted"}"><input id="card-payment-choice" type="radio" name="payment_method" value="card" ${S.cardEnabled ? "" : "disabled"}>Tarjeta con Mercado Pago ${S.cardEnabled ? "" : "· lista para activar"}</label><p class="hint">Los datos de tarjeta se capturan en el formulario seguro de Mercado Pago y Yavoi! no recibe ni almacena el número o CVV.</p><div id="cash-options"><label class="check"><input id="need-change" type="checkbox">Voy a necesitar cambio</label><label id="tender-label" class="hidden">Pagaré con (MXN)<input name="cash_tender" type="number" step="0.01" min="${q.fare_cents / 100}" max="3000" value="${q.fare_cents / 100}"></label><p id="change-preview" class="hint">Paga el importe exacto al llegar a tu destino.</p></div><button class="btn wide" type="submit">Confirmar y solicitar ${I("arrow-right")}</button></form>`,
  );
  const tipCents = () => {
    const choice = $('[name=tip]:checked').value;
    return choice === "custom" ? cents($('[name=custom_tip]').value || 0) : Math.round(q.fare_cents * Number(choice) / 100);
  };
  const selectedReward = () => tripRewards.find((reward) => reward.code === $('[name=reward_code]')?.value);
  const payableTotal = () => q.fare_cents - rewardDiscountCents(selectedReward(), q) + tipCents();
  const updateTotal = () => {
    let tip = 0;
    try { tip = tipCents(); } catch {}
    const reward = selectedReward();
    const discount = rewardDiscountCents(reward, q);
    const total = q.fare_cents - discount + tip;
    $("#custom-tip-label").classList.toggle("hidden", $('[name=tip]:checked').value !== "custom");
    $("#tip-preview").textContent = money(tip);
    $(".reward-discount-row").classList.toggle("hidden", !reward);
    $("#reward-preview-name").textContent = reward?.kind === "ride_amenity" ? `Amenidad · ${reward.name}` : `Recompensa · ${reward?.name || ""}`;
    $("#reward-preview-value").textContent = discount ? `-${money(discount)}` : "Incluida";
    $("#total-preview").textContent = money(total);
    $("#card-payment-choice").disabled = !S.cardEnabled || total === 0;
    if (total === 0 && $("#card-payment-choice").checked) $('[name=payment_method][value=cash]').checked = true;
    $('[name=cash_tender]').min = total / 100;
    if (!$("#need-change").checked) $('[name=cash_tender]').value = total / 100;
    $("#cash-options").classList.toggle("hidden", $('[name=payment_method]:checked').value === "card");
    updateChange();
  };
  $$('[name=tip]').forEach((input) => input.onchange = updateTotal);
  $('[name=custom_tip]').oninput = updateTotal;
  $('[name=reward_code]')?.addEventListener("change", updateTotal);
  $$('[name=payment_method]').forEach((input) => input.onchange = () => $("#cash-options").classList.toggle("hidden", input.value === "card" && input.checked));
  $("#need-change").onchange = (ev) => {
    $("#tender-label").classList.toggle("hidden", !ev.target.checked);
    if (!ev.target.checked) $("[name=cash_tender]").value = q.fare_cents / 100;
    updateChange();
  };
  function updateChange() {
    try {
      $("#change-preview").textContent =
        "Cambio estimado: " + money(changeDue(payableTotal(), cents($("[name=cash_tender]").value)));
    } catch {}
  }
  $("[name=cash_tender]").oninput = updateChange;
  const requestKey = crypto.randomUUID();
  bindForm("#payment", async (v) => {
    const tip = tipCents();
    const method = v.payment_method;
    const total = payableTotal();
    const t = await rpc("request_trip", {
      quote_id: q.id,
      request_key: requestKey,
      payment_method: method,
      cash_tender_cents: method === "cash" ? ($("#need-change").checked ? cents(v.cash_tender) : total) : null,
      tip_cents: tip,
      preferred_driver_id: q.preferred_driver_id,
      reward_code: v.reward_code || null,
    });
    closeModal();
    S.quote = null;
    S.data.ride_draft = null;
    if (t.payment_method === "card" && t.total_cents > 0) return cardCheckout(t.payment_id, t.id, t.total_cents);
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
  const gross = completed.reduce((n, t) => n + (t.total_cents ?? t.fare_cents), 0);
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
  return `<div class="table-wrap"><table><thead><tr><th>Folio / fecha</th><th>Recorrido</th><th>Estado</th><th>Pago</th><th>Importe</th><th>Valoración</th><th></th></tr></thead><tbody id="trip-rows">${tripRows(S.data.trips)}</tbody></table></div>${!S.data.trips.length ? `<div class="empty">${I("route")}<h3>Tu historial empieza con el primer viaje</h3><p>Los viajes guardados aparecerán aquí.</p></div>` : ""}`;
}
function tripRows(ts) {
  return ts
    .map(
      (t) =>
        `<tr><td><strong>${e(t.id.slice(0, 8).toUpperCase())}</strong><small>${date(t.created_at)}</small></td><td>${e(t.origin)}<small>${e(t.destination)}</small></td><td>${badge(t)}</td><td>${t.payment_method === "card" ? "Tarjeta" : "Efectivo"}<small>${e({ paid: "Confirmado", pending: "Pendiente", failed: "No aprobado", cancelled: "Cancelado sin cobro", refund_pending: "Reembolso pendiente", refunded: "Reembolsado" }[t.payment_status] || t.payment_status)}</small></td><td>${money(t.total_cents ?? t.fare_cents)}</td><td>${t.rating_given ? `<span class="trip-rating-inline">${I("star")} ${t.rating_given}/5</span><small>Tu valoración</small>` : t.rating_received ? `<span class="trip-rating-inline">${I("star")} ${t.rating_received}/5</span><small>Valoración recibida</small>` : '<small>Sin valorar</small>'}</td><td><a class="link" href="#trip/${e(t.id)}">Ver viaje</a></td></tr>`,
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
function tripRatingsMarkup(ratings = []) {
  const cards = ratings.map((rating) => {
    const relationship = rating.author_id === S.user.id
      ? `Tu valoración para ${rating.recipient_role === "driver" ? "el conductor" : "el pasajero"}`
      : rating.recipient_id === S.user.id
        ? `Valoración que recibiste de ${rating.author_role === "driver" ? "tu conductor" : "tu pasajero"}`
        : `${rating.author_name} valoró a ${rating.recipient_name}`;
    return `<article class="trip-rating-card"><div class="row between wrap"><div><small>${e(relationship)}</small><strong>${e(rating.author_name)} → ${e(rating.recipient_name)}</strong></div><span class="trip-rating-score">${I("star")} ${rating.stars}/5</span></div>${rating.comfort || rating.safety ? `<div class="meta-row">${rating.comfort ? `<span>Comodidad ${rating.comfort}/5</span>` : ""}${rating.safety ? `<span>Seguridad ${rating.safety}/5</span>` : ""}</div>` : ""}<p>${e(rating.comment || "Sin comentario escrito.")}</p><small>${date(rating.created_at)}</small></article>`;
  }).join("");
  return `<section class="trip-ratings"><h3>Valoraciones de este viaje</h3>${cards || '<p class="hint">Este viaje todavía no tiene una valoración registrada.</p>'}</section>`;
}
async function tripView(id) {
  S.trip = await rpc("trip", { trip_id: id });
  const { trip: t, driver, passenger, location: loc, pin, my_rating } = S.trip;
  await Promise.all([
    loadAvatar(driver?.avatar_path),
    loadAvatar(passenger?.avatar_path),
    loadVehiclePhoto(driver?.vehicle_front_path),
  ]);
  const rider = S.user.id === t.passenger_id,
    conductor = S.user.id === t.driver_id;
  const person = rider ? driver : passenger;
  const vehiclePhoto = rider && driver?.vehicle_front_path
    ? S.vehiclePhotoUrls[driver.vehicle_front_path]
    : "";
  const title = statuses[t.status] || t.status;
  const progress = ["requested", "accepted", "arrived", "in_progress", "completed"].indexOf(
    t.status,
  );
  const ridePayment = S.trip.payments?.find((payment) => payment.kind === "ride");
  const cancellationPayment = S.trip.payments?.find((payment) => payment.kind === "cancellation_fee");
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
                  : `La solicitud fue cancelada${t.cancelled_by_role ? ` por ${t.cancelled_by_role === "passenger" ? "el pasajero" : t.cancelled_by_role === "driver" ? "el conductor" : "Operaciones"}` : ""}.`;
  const serviceDetails = `<div class="service-summary"><div>${I("users-round")}<span><small>Personas</small><strong>${t.party_size || 1}</strong></span></div><div>${I(t.accessible ? "accessibility" : "car-front")}<span><small>Servicio</small><strong>Yavoi! ${e(S.categories.find((category) => category.id === t.category)?.name || t.category)}</strong></span></div>${t.service_notes ? `<div class="wide-detail">${I("message-square-text")}<span><small>Petición del pasajero</small><strong>${e(t.service_notes)}</strong></span></div>` : ""}</div>`;
  const rewardPaymentRow = t.reward_discount_cents
    ? `<div class="receipt-row positive-points"><span>Recompensa Puntos Viajeros</span><strong>-${money(t.reward_discount_cents)}</strong></div>`
    : "";
  let paymentRows = serviceDetails + (t.payment_method === "card"
    ? `<div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${rewardPaymentRow}${t.tip_cents ? `<div class="receipt-row"><span>Propina</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total · tarjeta</span><strong>${money(t.total_cents ?? t.fare_cents)}</strong></div><p class="hint">Estado del pago: ${e({ paid: "Confirmado", pending: "En proceso", failed: "No aprobado", refund_pending: "Reembolso en proceso", refunded: "Reembolsado" }[t.payment_status] || t.payment_status)}</p>`
    : `<div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${rewardPaymentRow}${t.tip_cents ? `<div class="receipt-row"><span>Propina voluntaria</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total · efectivo</span><strong>${money(t.total_cents ?? t.fare_cents)}</strong></div>${Number(t.total_cents || 0) > 0 ? `<div class="receipt-row"><span>Pago con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row"><span>Cambio</span><strong>${money(changeDue(t.total_cents ?? t.fare_cents, t.cash_tender_cents))}</strong></div>` : '<p class="hint">Viaje cubierto por tu recompensa. No entregues efectivo por la tarifa.</p>'}`);
  if (t.status === "cancelled") {
    const feeStatus = cancellationPayment
      ? ({ pending: "Pendiente de confirmar", approved: "Confirmada", cancelled: "Condonada" }[cancellationPayment.status] || cancellationPayment.status)
      : Number(t.cancellation_fee_cents || 0) > 0 && t.payment_method === "card"
        ? "Retenida del pago electrónico"
        : "Sin cargo";
    paymentRows = `${serviceDetails}<section class="cancellation-summary"><h3>Detalle de cancelación</h3><div class="receipt-row"><span>Importe original</span><strong>${money(t.total_cents ?? t.fare_cents)}</strong></div><div class="receipt-row"><span>Cuota de cancelación</span><strong>${money(t.cancellation_fee_cents || 0)}</strong></div>${t.payment_method === "card" ? `<div class="receipt-row"><span>Reembolso</span><strong>${money(t.cancellation_refund_cents || 0)}</strong></div>` : ""}<div class="receipt-row"><span>Estado</span><strong>${e(feeStatus)}</strong></div><p class="hint">${e(t.cancel_reason || "Sin motivo registrado.")} · Política ${e(t.cancellation_policy_version || "vigente al cancelar")}.</p></section>`;
  }
  if (S.profile.role === "admin" && S.trip.operations) {
    const operations = S.trip.operations;
    const expected = Number(t.total_cents ?? t.fare_cents ?? 0);
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
    (rider || conductor) && t.driver_id && ["accepted", "arrived", "in_progress"].includes(t.status)
      ? `<section class="ride-safety-actions" aria-label="Ayuda y seguridad durante el viaje"><button class="btn secondary" data-action="trip-report">${I("message-square-warning")} Reportar este viaje</button><a class="btn danger" href="tel:911">${I("phone-call")} Emergencias 911</a></section>`
      : "";
  const chatAction = t.driver_id && active(t) && (rider || conductor)
    ? button(rider ? "Mensajear con mi conductor" : "Mensajear con mi pasajero", "open-chat", "secondary wide section-gap", "message-circle")
    : "";
  const terminalReport = (rider || conductor) && ["completed", "cancelled"].includes(t.status)
    ? button("Reportar este servicio", "trip-report", "secondary", "message-square-warning")
    : "";
  const reportHistory = (S.trip.reports || []).length
    ? `<section class="trip-reports"><h3>Seguimiento de reportes</h3>${S.trip.reports.map((report) => `<article><div class="row between wrap"><strong>${e(report.subject)}</strong><span class="badge ${report.status === "resolved" ? "" : "pending"}">${e({ open: "Abierto", reviewing: "En revisión", resolved: "Resuelto" }[report.status] || report.status)}</span></div><p>${e(report.body)}</p>${report.response ? `<p class="hint">Respuesta de Operaciones: ${e(report.response)}</p>` : ""}<small>${date(report.created_at)}</small></article>`).join("")}</section>`
    : "";
  const cancellationFeeActions = t.status === "cancelled" && cancellationPayment?.status === "pending" && (conductor || S.profile.role === "admin")
    ? `<div class="row wrap section-gap">${button("Confirmar cuota recibida", "settle-cancel-fee", "secondary", "circle-dollar-sign")}${S.profile.role === "admin" ? button("Condonar cuota", "waive-cancel-fee", "secondary", "badge-x") : ""}</div>`
    : "";
  const navigationUrl = conductor && ["accepted", "arrived", "in_progress"].includes(t.status) ? googleNavigationUrl(t) : "";
  const driverNavigation = navigationUrl
    ? `<a class="btn navy wide section-gap" href="${e(navigationUrl)}" target="_blank" rel="noopener noreferrer">${I("navigation")} ${t.status === "in_progress" ? "Navegar al destino" : "Navegar a recoger al pasajero"}</a>`
    : "";
  const tripFooter = `<div class="row wrap section-gap">${button("Compartir resumen", "share", "secondary", "share-2")}${terminalReport}</div>`;
  shell(
    `<div class="trip-layout"><section class="panel trip-panel">${badge(t)}<h2 class="big-status">${e(title)}</h2><p>${e(statusMessage)}</p><div class="stepper" aria-hidden="true">${[0, 1, 2, 3, 4].map((i) => `<span class="${i <= progress ? "done" : ""}"></span>`).join("")}</div><div class="route-line">${I("circle-dot")}${e(t.origin)}</div><div class="route-line destination">${I("map-pin")}${e(t.destination)}</div>${t.scheduled_at ? `<p class="hint">${I("calendar")} ${date(t.scheduled_at)}</p>` : ""}${person ? `<div class="person-card">${avatar(person.name, person.avatar_path, "big")}<div><small>${rider ? "Tu conductor" : "Tu pasajero"}</small><strong style="display:block;margin-top:5px">${e(person.name)}</strong>${rider ? `<p>${e([driver.vehicle_color, driver.vehicle_make, driver.vehicle_model, driver.vehicle_year].filter(Boolean).join(" ") || driver.vehicle)} · ${e(driver.plate)}</p><small>Calificación: ${driver.rating || "Nuevo conductor"}</small>` : ""}</div></div>` : ""}${vehiclePhoto ? `<figure class="assigned-vehicle-photo"><img src="${e(vehiclePhoto)}" alt="Fotografía frontal del vehículo asignado, placa ${e(driver.plate)}"><figcaption>Unidad verificada · confirma que la placa visible coincida con <strong>${e(driver.plate)}</strong></figcaption></figure>` : ""}${chatAction}${pin ? `<div class="pin-card"><span>Tu PIN de inicio<br><small>No lo compartas antes de abordar</small></span><strong>${e(pin)}</strong></div>` : ""}${t.distance_km != null ? `<div class="estimate-grid compact"><div><small>Recogida estimada</small><strong>${decimal(t.pickup_distance_km)} km · ${t.pickup_eta_minutes} min</strong></div><div><small>Recorrido estimado</small><strong>${decimal(t.distance_km)} km · ${t.trip_eta_minutes} min</strong><span>${zoneLabel(t.service_zone)}</span></div></div>` : ""}${paymentRows}${action}${driverNavigation}${tripSafetyControls}${cancellationFeeActions}${conductor && active(t) && t.status !== "payment_pending" ? `<div class="section-gap">${button("Actualizar ubicación ahora", "gps", "secondary wide", "locate-fixed")}<p class="hint">La ubicación se actualiza automáticamente mientras Yavoi! permanece abierto y se recupera al volver a la página.</p></div>` : ""}${t.status === "completed" && !my_rating && (rider || conductor) ? button(rider ? "Valorar viaje y conductor" : "Valorar pasajero", "rate", "wide", "star") : ""}${my_rating ? `<p class="hint">Evaluación enviada: ${my_rating.stars}/5. Gracias por compartir tu experiencia.</p>` : ""}${t.status === "completed" ? tripRatingsMarkup(S.trip.ratings || []) : ""}${t.status === "completed" && conductor ? button("Registrar propina recibida", "tip", "secondary wide section-gap", "heart") : ""}${t.status === "completed" && rider ? button("Agregar propina", "passenger-tip", "secondary wide section-gap", "heart") : ""}${t.status === "completed" ? button("Ver recibo", "receipt", "secondary wide section-gap", "receipt-text") : ""}${active(t) && t.status !== "in_progress" && t.status !== "payment_pending" ? button("Cancelar viaje", "cancel", "danger wide section-gap", "x") : ""}${S.profile.role === "admin" && t.status === "arrived" ? button("Renovar PIN bloqueado", "reset-pin", "secondary wide section-gap", "key-round") : ""}${S.profile.role === "admin" && t.status === "in_progress" ? button("Cancelar por incidencia", "cancel", "danger wide section-gap", "shield-alert") : ""}${reportHistory}${tripFooter}</section><div class="stack"><div id="route-monitor">${routeMonitorMarkup()}</div>${mapFrame("ride-map", e(geo))}<details class="panel route-guide" open><summary>${I("signpost")} Ruta sugerida y guía por calles</summary><div id="route-guide-content">${routeGuideMarkup(null)}</div></details><section class="panel trip-chat-panel" id="trip-chat"><div class="row between wrap"><div><h2>Mensajes del viaje</h2><p>Disponible desde que el conductor acepta y mientras el viaje está activo.</p></div>${I("message-circle")}</div><div id="chat" class="chat">${messagesHtml(S.trip.messages)}</div>${conductor || rider ? `<form id="chat-form" class="chat-form"><input name="body" aria-label="Mensaje" placeholder="Confirma una entrada, referencia o indicación…" required maxlength="1000" ${!t.driver_id || !active(t) ? "disabled" : ""}><button class="btn" type="submit" aria-label="Enviar mensaje" ${!t.driver_id || !active(t) ? "disabled" : ""}>${I("send")}</button></form>` : ""}<p class="hint">Para una emergencia real, llama al <a href="tel:911" class="link">911</a>. El chat no es un servicio de atención inmediata.</p></section></div></div>`,
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
  const chat = $("#chat");
  if (chat) {
    const followLatest = chat.scrollHeight - chat.scrollTop - chat.clientHeight < 80;
    chat.innerHTML = messagesHtml(next.messages);
    if (followLatest) chat.scrollTop = chat.scrollHeight;
  }
  updateTripMap();
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
const settlementStatusName = { pending: "Pendiente", submitted: "En revisión", paid: "Pagada", overdue: "Vencida", waived: "Condonada" };
function driverBillingCard() {
  const d = S.driver || {};
  const weekly = d.billing_mode !== "commission";
  return `<section class="panel billing-summary"><div class="row between wrap"><div><div class="eyebrow">TU MODALIDAD ACTUAL</div><h2>${weekly ? "Aportación semanal" : "Comisión por viaje"}</h2></div><span class="badge">${weekly ? money(d.weekly_fee_cents || 50000) + " por semana" : "Sin aportación semanal"}</span></div><div class="grid2 billing-rules"><div>${I("banknote")}<span><small>VIAJES EN EFECTIVO</small><strong>${weekly ? "100% para ti" : `${100 - Number(d.cash_commission_bps || 2000) / 100}% para ti`}</strong><p>${weekly ? "No generan comisión adicional." : `${Number(d.cash_commission_bps || 2000) / 100}% se liquida semanalmente a Yavoi!.`}</p></span></div><div>${I("credit-card")}<span><small>PAGO ELECTRÓNICO</small><strong>${100 - Number(d.card_commission_bps || (weekly ? 1000 : 2000)) / 100}% para ti</strong><p>La comisión de ${Number(d.card_commission_bps || (weekly ? 1000 : 2000)) / 100}% se retiene al conciliar el pago.</p></span></div></div><p class="hint">Operaciones administra esta modalidad. Cada viaje conserva el porcentaje vigente cuando lo aceptaste.</p></section>`;
}
function driverSettlementsMarkup() {
  const settlements = S.data.commission_settlements || [];
  if (S.driver?.billing_mode !== "commission") return "";
  return `<section class="panel section-gap"><div class="row between wrap"><div><h2>Liquidación semanal de efectivo</h2><p>Transfiere únicamente la comisión Yavoi! de los viajes que cobraste en efectivo.</p></div><span class="badge ${settlements.some((item) => ["pending", "overdue"].includes(item.status)) ? "pending" : ""}">${settlements.filter((item) => ["pending", "overdue", "submitted"].includes(item.status)).length} por conciliar</span></div><div class="settlement-list">${settlements.length ? settlements.map((item) => `<article class="settlement-card"><div><strong>Semana del ${new Date(item.week_start + "T12:00:00").toLocaleDateString("es-MX", { dateStyle: "medium" })}</strong><small>Vence ${date(item.due_at)} · Efectivo cobrado ${money(item.gross_cash_cents)}</small></div><div><small>COMISIÓN A TRANSFERIR</small><strong>${money(item.commission_due_cents)}</strong></div><span class="badge ${["pending", "overdue", "submitted"].includes(item.status) ? "pending" : ""}">${e(settlementStatusName[item.status] || item.status)}</span>${["pending", "overdue"].includes(item.status) ? `<form class="settlement-proof" data-settlement-form="${e(item.id)}"><label>Comprobante · PDF, JPG o PNG<input name="proof" type="file" accept="application/pdf,image/jpeg,image/png" required></label><button class="btn" type="submit">Enviar transferencia ${I("upload")}</button></form>` : item.proof_path ? '<small>Comprobante enviado a Operaciones.</small>' : ""}</article>`).join("") : '<div class="empty"><p>La primera liquidación aparecerá al completar un viaje en efectivo.</p></div>'}</div></section>`;
}
function wallet() {
  const driver = S.profile.role !== "passenger";
  const completed = S.data.trips.filter((t) => t.status === "completed");
  const total = driver
    ? S.data.ledger.reduce((n, l) => n + l.amount_cents, 0)
    : completed.reduce((n, t) => n + (t.total_cents ?? t.fare_cents), 0);
  const ledgerNames = { fare: "Tarifa cobrada", commission: "Comisión Yavoi!", cash_tip: "Propina en efectivo", card_tip: "Propina electrónica" };
  shell(
    `${driver ? driverBillingCard() : ""}<div class="balance ${driver ? "section-gap" : ""}"><small>${driver ? "INGRESO NETO REGISTRADO" : "TOTAL DE VIAJES COMPLETADOS"}</small><h2>${money(total)}</h2><p>${driver ? "Tarifas, menos la comisión aplicable a cada viaje, más todas tus propinas." : "Pagos registrados por viajes completados."}</p></div><div class="grid2"><section class="panel"><h2>${driver ? "Tus movimientos" : "Métodos de pago"}</h2>${driver ? (S.data.ledger.length ? S.data.ledger.map((l) => `<div class="receipt-row"><div>${e(ledgerNames[l.kind] || l.kind)}<small style="display:block">${date(l.created_at)}</small></div><strong>${money(l.amount_cents)}</strong></div>`).join("") : "<p>Aún no hay movimientos.</p>") : `<div class="row">${I("banknote")}<strong>Efectivo</strong><span class="badge">Disponible</span></div><p class="hint">Indica si necesitas cambio antes de solicitar. El conductor verá el monto con el que pagarás.</p><div class="row muted">${I("credit-card")}<strong>Tarjeta</strong><span class="badge neutral">Próximamente</span></div><p class="hint">No se guardan datos de tarjeta. Esta opción se activará al conectar un proveedor de pagos.</p>`}</section><section class="panel"><h2>${driver ? "Cómo se calcula" : "Cada peso, con claridad"}</h2><p>${driver ? "La tarifa y la propina se muestran por separado. Las propinas son 100% tuyas; el porcentaje comercial sólo se calcula sobre la tarifa del viaje." : "La tarifa se muestra antes de confirmar. La propina es voluntaria y puedes entregarla directamente en efectivo."}</p><p class="hint">${driver ? "En pagos electrónicos Yavoi! registra el monto neto. En efectivo, una comisión pendiente aparece en la liquidación semanal sólo cuando tu modalidad es por comisión." : "Cada cobro queda relacionado con el viaje y su recibo."}</p><a class="btn secondary" href="#trips">Consultar mis viajes ${I("arrow-right")}</a></section></div>${driver ? driverSettlementsMarkup() : ""}`,
    driver ? "Tus ingresos, siempre claros." : "Tu cartera Yavoi!",
    "Consulta importes, porcentajes aplicados y liquidaciones.",
  );
  if (!driver && S.cardEnabled) {
    const cardRow = $(".row.muted");
    cardRow?.classList.remove("muted");
    const cardBadge = $(".badge", cardRow);
    if (cardBadge) cardBadge.textContent = "Disponible";
    const note = cardRow?.nextElementSibling;
    if (note) note.textContent = "Tarjeta protegida por Mercado Pago, disponible al solicitar el viaje y para propinas posteriores.";
  }
  $$("[data-settlement-form]").forEach((form, index) => {
    form.id = `settlement-proof-${index}`;
    bindForm("#" + form.id, async (_values, currentForm) => {
      const path = await upload(currentForm.elements.proof.files[0], "yavoi-payment-proofs");
      await rpc("submit_driver_settlement", { settlement_id: form.dataset.settlementForm, proof_path: path });
      await refreshPage();
      notify("Transferencia enviada a revisión de Operaciones.");
    });
  });
}
function weeklyProfileMarkup() {
  if (S.driver?.billing_mode === "commission")
    return `<details class="profile-section weekly-profile"><summary><span>${I("circle-dollar-sign")}<strong>Modalidad de ingresos</strong></span><span class="badge neutral">Comisión por viaje</span></summary><div class="profile-section-body"><p>No tienes aportación semanal. Las comisiones de efectivo se concentran por semana en <a class="link" href="#wallet">Mis ingresos</a>; las electrónicas se descuentan al conciliar cada pago.</p></div></details>`;
  const fees = (S.data.weekly_fees || []).filter((fee) => fee.status !== "waived");
  const current = fees[0];
  const statusName = { pending: "Pendiente", submitted: "En revisión", paid: "Pagada", overdue: "Vencida", waived: "Condonada" };
  return `<details class="profile-section weekly-profile" open><summary><span>${I("calendar-check")}<strong>Cuota semanal</strong></span><span class="badge ${current && ["pending", "submitted", "overdue"].includes(current.status) ? "pending" : ""}">${current ? e(statusName[current.status]) : "Sin cuota activa"}</span></summary><div class="weekly-summary"><div><small>CUOTA SEMANAL DE USO</small><strong>${money(current?.amount_cents || S.driver?.weekly_fee_cents || 50000)}</strong><p>${current ? `Semana del ${new Date(current.week_start + "T12:00:00").toLocaleDateString("es-MX", { dateStyle: "long" })} · vence ${date(current.due_at)}` : "La cuota aparecerá al aprobarse tu expediente."}</p></div></div><div class="grid2 weekly-grid"><section><h3>Semana actual</h3>${current && !["paid", "waived"].includes(current.status) ? `<form id="weekly-proof"><p>Sube el comprobante de ${money(current.amount_cents)}. Operaciones verificará el depósito y habilitará la cuenta.</p><label>Comprobante · PDF, JPG o PNG hasta 5 MB<input name="proof" type="file" accept="application/pdf,image/jpeg,image/png" required></label><button class="btn wide" type="submit">Enviar comprobante ${I("upload")}</button></form>` : `<p>${current ? "Tu cuota de esta semana está cubierta." : "Aún no existe una cuota activa."}</p>`}</section><section><h3>Calendario de cuotas</h3>${fees.length ? fees.map((fee) => `<div class="fee-row"><div><strong>${new Date(fee.week_start + "T12:00:00").toLocaleDateString("es-MX", { day: "2-digit", month: "short", year: "numeric" })}</strong><small>Vence ${date(fee.due_at)}</small></div><span class="badge ${["pending", "submitted", "overdue"].includes(fee.status) ? "pending" : ""}">${e(statusName[fee.status])}</span><strong>${money(fee.amount_cents)}</strong></div>`).join("") : '<p class="muted">Sin cuotas registradas.</p>'}</section></div></details>`;
}
function bindWeeklyProof() {
  const current = (S.data.weekly_fees || []).find((fee) => fee.status !== "waived");
  if (!current || !$("#weekly-proof")) return;
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
  const settlements = S.data.commission_settlements || [];
  const approved = payments.filter((payment) => payment.status === "approved").reduce((sum, payment) => sum + payment.amount_cents, 0);
  const statusName = { created: "Creado", pending: "Pendiente", in_process: "Procesando", approved: "Aprobado", rejected: "Rechazado", cancelled: "Cancelado", refund_pending: "Reembolso pendiente", refunded: "Reembolsado", submitted: "En revisión", paid: "Pagada", overdue: "Vencida", waived: "Condonada" };
  const feeCards = fees.filter((fee) => fee.note !== "Modalidad por comisión").map((fee) => `<article class="fee-card"><div><strong>${e(fee.driver_name)}</strong><small>Semana ${e(fee.week_start)} · vence ${date(fee.due_at)}</small></div><strong>${money(fee.amount_cents)}</strong><span class="badge ${["pending", "submitted", "overdue"].includes(fee.status) ? "pending" : ""}">${e(statusName[fee.status])}</span><div class="row wrap">${fee.proof_path ? `<button class="btn secondary" data-fee-proof="${e(fee.proof_path)}">Ver comprobante</button>` : ""}${fee.status === "submitted" ? `<button class="btn" data-fee-review="${e(fee.id)}">Revisar pago</button>` : ""}<button class="btn ${fee.account_active ? "danger" : "secondary"}" data-driver-access="${e(fee.driver_id)}" data-active="${fee.account_active ? "false" : "true"}">${fee.account_active ? "Desactivar cuenta" : "Activar cuenta"}</button></div></article>`).join("");
  const settlementCards = settlements.map((item) => `<article class="fee-card"><div><strong>${e(item.driver_name)}</strong><small>Semana ${e(item.week_start)} · efectivo ${money(item.gross_cash_cents)}</small></div><strong>${money(item.commission_due_cents)}</strong><span class="badge ${["pending", "submitted", "overdue"].includes(item.status) ? "pending" : ""}">${e(statusName[item.status] || item.status)}</span><div class="row wrap">${item.proof_path ? `<button class="btn secondary" data-settlement-proof="${e(item.proof_path)}">Ver transferencia</button>` : ""}${item.status === "submitted" ? `<button class="btn" data-settlement-review="${e(item.id)}">Revisar liquidación</button>` : ""}</div></article>`).join("");
  shell(
    `<div class="grid4 stats"><div class="stat"><small>Pagos registrados</small><strong>${payments.length}</strong><p>Efectivo, tarjeta, cancelaciones y aportaciones</p></div><div class="stat"><small>Importe aprobado</small><strong>${money(approved)}</strong><p>Conciliación del sistema</p></div><div class="stat"><small>Comprobantes por revisar</small><strong>${fees.filter((fee) => fee.status === "submitted").length + settlements.filter((item) => item.status === "submitted").length}</strong><p>Aportaciones y comisiones</p></div><div class="stat"><small>Reembolsos pendientes</small><strong>${payments.filter((payment) => payment.status === "refund_pending").length}</strong><p>Requieren seguimiento</p></div></div><section class="panel section-gap"><h2>Registro de pagos</h2><div class="table-wrap"><table><thead><tr><th>Fecha / referencia</th><th>Concepto</th><th>Viaje y personas</th><th>Método</th><th>Estado</th><th>Importe</th><th></th></tr></thead><tbody>${payments.map((payment) => `<tr><td>${date(payment.created_at)}<small>${e(payment.provider_payment_id || payment.id.slice(0, 8))}</small></td><td>${e({ ride: "Viaje", tip: "Propina", weekly_fee: "Aportación semanal", cancellation_fee: "Cuota de cancelación" }[payment.kind] || payment.kind)}</td><td>${e(payment.origin || "Sin viaje")}<small>${e(payment.payer_name || "")} ${payment.driver_name ? `· ${e(payment.driver_name)}` : ""}</small></td><td>${e({ cash: "Efectivo", mercado_pago: "Mercado Pago", manual: "Comprobante" }[payment.provider])}</td><td><span class="badge ${["created", "pending", "in_process", "refund_pending"].includes(payment.status) ? "pending" : payment.status === "rejected" ? "cancelled" : ""}">${e(statusName[payment.status] || payment.status)}</span></td><td><strong>${money(payment.amount_cents)}</strong>${payment.refund_amount_cents ? `<small>Reembolso ${money(payment.refund_amount_cents)}</small>` : ""}${payment.retained_amount_cents ? `<small>Retenido ${money(payment.retained_amount_cents)}</small>` : ""}</td><td>${payment.status === "refund_pending" ? `<button class="link" data-refund="${e(payment.id)}">Procesar reembolso</button>` : ""}</td></tr>`).join("")}</tbody></table></div></section><section class="panel section-gap"><h2>Aportaciones semanales</h2><p>Conductores configurados con cuota fija; conservan el 100% del efectivo y el porcentaje configurado de pagos electrónicos.</p>${feeCards || '<div class="empty"><p>No hay aportaciones activas.</p></div>'}</section><section class="panel section-gap"><h2>Liquidaciones de comisión en efectivo</h2><p>Conductores sin cuota semanal que transfieren la comisión acumulada de sus viajes en efectivo.</p>${settlementCards || '<div class="empty"><p>No hay liquidaciones registradas.</p></div>'}</section>`,
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
  $$('[data-settlement-proof]').forEach((item) => item.onclick = () => run(async () => {
    const { data, error } = await db.storage.from("yavoi-payment-proofs").createSignedUrl(item.dataset.settlementProof, 60);
    if (error) throw error;
    openModal("Transferencia privada", `<p>El enlace vence en un minuto.</p><a class="btn wide" href="${e(data.signedUrl)}" target="_blank" rel="noopener noreferrer">Abrir comprobante ${I("external-link")}</a>`);
  }));
  $$('[data-settlement-review]').forEach((item) => item.onclick = () => {
    openModal("Revisar liquidación de comisión", `<form id="settlement-review"><label>Resultado<select name="approved"><option value="true">Transferencia comprobada</option><option value="false">Rechazar comprobante</option></select></label><label>Nota de revisión<textarea name="note" minlength="5" maxlength="1000" required></textarea></label><button class="btn wide" type="submit">Guardar revisión</button></form>`);
    bindForm("#settlement-review", async (values) => {
      await rpc("review_driver_settlement", { settlement_id: item.dataset.settlementReview, approved: values.approved === "true", note: values.note });
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
const rewardStatusName = {
  available: "Lista para usar",
  requested: "Solicitada",
  applied: "Aplicada",
  fulfilled: "Entregada",
  cancelled: "Cancelada",
  expired: "Vencida",
};
const code128Patterns = [
  "212222","222122","222221","121223","121322","131222","122213","122312","132212","221213","221312","231212",
  "112232","122132","122231","113222","123122","123221","223211","221132","221231","213212","223112","312131",
  "311222","321122","321221","312212","322112","322211","212123","212321","232121","111323","131123","131321",
  "112313","132113","132311","211313","231113","231311","112133","112331","132131","113123","113321","133121",
  "313121","211331","231131","213113","213311","213131","311123","311321","331121","312113","312311","332111",
  "314111","221411","431111","111224","111422","121124","121421","141122","141221","112214","112412","122114",
  "122411","142112","142211","241211","221114","413111","241112","134111","111242","121142","121241","114212",
  "124112","124211","411212","421112","421211","212141","214121","412121","111143","111341","131141","114113",
  "114311","411113","411311","113141","114131","311141","411131","211412","211214","211232","2331112",
];
function rewardBarcode(code) {
  const safe = String(code || "").toUpperCase().replace(/[^\x20-\x7e]/g, "").slice(0, 40);
  const values = [...safe].map((character) => character.charCodeAt(0) - 32);
  let checksum = 104;
  values.forEach((value, index) => { checksum += value * (index + 1); });
  const patterns = [104, ...values, checksum % 103, 106].map((value) => code128Patterns[value]);
  let x = 10;
  const bars = [];
  patterns.forEach((pattern) => {
    [...pattern].forEach((width, index) => {
      const size = Number(width);
      if (index % 2 === 0) bars.push(`<rect x="${x}" y="2" width="${size}" height="58"/>`);
      x += size;
    });
  });
  return `<svg class="coupon-barcode" viewBox="0 0 ${x + 10} 64" role="img" aria-label="Código de barras ${e(safe)}" preserveAspectRatio="none">${bars.join("")}</svg>`;
}
function rewardImageUrl(path) {
  return path ? db.storage.from("yavoi-marketing").getPublicUrl(path).data.publicUrl || "" : "";
}
function openRewardCoupon(redemption) {
  const image = rewardImageUrl(redemption.image_path);
  const usable = redemption.status === "available";
  openModal(
    usable ? "Tu cupón está listo" : "Detalle de tu recompensa",
    `<article class="reward-coupon" id="reward-coupon-card">${image ? `<img class="reward-coupon-logo" src="${e(image)}" alt="${e(redemption.partner_name || redemption.name)}">` : `<div class="reward-coupon-brand">Yavoi!</div>`}<div class="reward-coupon-copy"><span class="badge ${usable ? "" : "pending"}">${e(rewardStatusName[redemption.status] || redemption.status)}</span><small>${e(redemption.partner_name || "Yavoi!")}</small><h3>${e(redemption.name)}</h3><p>${e(redemption.description)}</p></div><div class="reward-coupon-code">${rewardBarcode(redemption.code)}<strong>${e(redemption.code)}</strong><small>Código individual e irrepetible</small></div>${redemption.terms || redemption.fulfillment_note ? `<div class="reward-coupon-terms"><strong>Condiciones</strong><p>${e(redemption.terms || redemption.fulfillment_note)}</p></div>` : ""}<div class="reward-coupon-meta"><span>Propietario: ${e(S.profile.full_name)}</span>${redemption.expires_at ? `<span>Válido hasta: ${date(redemption.expires_at)}</span>` : ""}</div></article><div class="coupon-actions"><button class="btn" id="share-reward-coupon">Compartir cupón ${I("share-2")}</button><button class="btn secondary" id="copy-reward-code">Copiar código ${I("copy")}</button></div><p class="hint">Puedes compartirlo desde tu teléfono o guardar una captura de esta pantalla. No publiques el código hasta el momento de utilizarlo.</p>`,
  );
  $("#share-reward-coupon").onclick = () => run(async () => {
    const text = `${redemption.name}\n${redemption.partner_name || "Yavoi!"}\nCódigo: ${redemption.code}${redemption.expires_at ? `\nVálido hasta: ${date(redemption.expires_at)}` : ""}`;
    if (navigator.share) await navigator.share({ title: `Cupón Yavoi! · ${redemption.name}`, text });
    else {
      await navigator.clipboard.writeText(text);
      notify("Datos del cupón copiados para compartir.");
    }
  });
  $("#copy-reward-code").onclick = () => run(async () => {
    await navigator.clipboard.writeText(redemption.code);
    notify("Código del cupón copiado.");
  });
}
function rewardEligibility(reward, metrics, systemEnabled = true) {
  if (!systemEnabled) return [false, "Sistema temporalmente pausado por Operaciones"];
  if (!reward.active) return [false, reward.partner_name === "Proveedor por definir" ? "Convenio por confirmar" : "Temporalmente no disponible"];
  if (reward.automatic) return [false, `Se genera cada ${reward.milestone_every} viajes`];
  if (metrics.available_points < reward.points_cost) return [false, `Te faltan ${reward.points_cost - metrics.available_points} puntos`];
  if (metrics.trip_count < reward.min_trips) return [false, `Requiere ${reward.min_trips} viajes`];
  if (reward.min_rating && Number(metrics.rating || 0) < Number(reward.min_rating)) return [false, `Requiere rating ${reward.min_rating}`];
  if (Number(metrics.income_cents || 0) < Number(reward.min_income_cents || 0)) return [false, `Requiere ${money(reward.min_income_cents)} generados`];
  if (reward.max_recent_incidents != null && metrics.recent_incidents > reward.max_recent_incidents) return [false, "Requiere historial reciente sin incidentes"];
  return [true, "Disponible para canjear"];
}
function rewardCard(reward, metrics, systemEnabled = true) {
  const [eligible, reason] = rewardEligibility(reward, metrics, systemEnabled);
  const image = rewardImageUrl(reward.image_path);
  return `<article class="reward-card ${eligible ? "eligible" : ""}">${image ? `<img class="reward-card-image" src="${e(image)}" alt="${e(reward.partner_name || reward.name)}">` : `<div class="reward-icon">${I(reward.icon || "gift")}</div>`}<div class="reward-card-copy"><div class="row between wrap"><h3>${e(reward.name)}</h3><strong>${reward.automatic ? "Meta automática" : `${reward.points_cost} pts`}</strong></div><p>${e(reward.description)}</p><small>${e(reason)}${reward.partner_name ? ` · ${e(reward.partner_name)}` : ""}</small></div>${!reward.automatic ? `<button class="btn ${eligible ? "" : "secondary"}" data-redeem="${e(reward.id)}" ${eligible ? "" : "disabled"}>${eligible ? "Canjear" : "Aún no disponible"}</button>` : ""}</article>`;
}
function rewards() {
  const wallet = S.data.reward_wallet || {};
  const driver = S.profile.role === "driver";
  const systemEnabled = S.data.marketing?.rewards_enabled !== false;
  const available = Number(wallet.available_points || 0);
  const lifetime = Number(wallet.lifetime_points || 0);
  const next = wallet.next_level_points ? Math.max(0, Number(wallet.next_level_points) - lifetime) : 0;
  const levelProgress = wallet.next_level_points
    ? Math.min(100, Math.round((lifetime / Number(wallet.next_level_points)) * 100))
    : 100;
  const catalog = (wallet.catalog || []).filter((reward) => !reward.automatic);
  const redemptions = wallet.redemptions || [];
  const activeBenefits = redemptions.filter((item) => ["available", "requested", "applied"].includes(item.status));
  const entries = wallet.entries || [];
  const freeRides = redemptions.filter((item) => item.kind === "free_local_trip" && item.status === "available");
  shell(
    `<div class="rewards reward-hero">${I(driver ? "star" : "gift")}<div><div class="eyebrow">${driver ? "RATING YAVOI!" : "PUNTOS VIAJEROS"}</div><h2>${driver ? `${e(wallet.level || "Activo")} · ${wallet.rating ? `${decimal(wallet.rating)}/5` : "sin rating aún"}` : `${e(wallet.level || "Explorador")} · cada viaje te acerca`}</h2><p>${driver ? "Suma por viajes, ingresos y calificaciones. Un historial limpio habilita mejores beneficios." : "Acumula puntos, canjea amenidades y descuentos, y recibe un viaje local Básico gratis cada 15 viajes."}</p></div><div class="points">${available}<small>PUNTOS DISPONIBLES</small></div></div>${systemEnabled ? "" : `<div class="notice-strip">${I("pause-circle")} Operaciones pausó temporalmente la acumulación y el canje. Tus puntos y recompensas guardadas se conservan.</div>`}<section class="panel reward-progress"><div class="row between wrap"><div><small>NIVEL ACTUAL</small><h2>${e(wallet.level || (driver ? "Activo" : "Explorador"))}</h2></div><div class="reward-metrics"><span><strong>${wallet.trip_count || 0}</strong> viajes</span>${driver ? `<span><strong>${wallet.rating ? decimal(wallet.rating) : "—"}</strong> rating</span><span><strong>${money(wallet.income_cents || 0)}</strong> generados</span><span><strong>${wallet.recent_incidents || 0}</strong> incidentes recientes</span>` : `<span><strong>${freeRides.length}</strong> viajes gratis guardados</span><span><strong>${wallet.trips_to_free_ride || 15}</strong> para el siguiente gratis</span>`}</div></div><progress max="100" value="${levelProgress}">${levelProgress}%</progress><p>${wallet.next_level ? `Faltan ${next} puntos para llegar a ${e(wallet.next_level)}.` : "Alcanzaste el nivel más alto del programa actual."}</p></section>${activeBenefits.length ? `<section class="panel section-gap"><h2>Tus recompensas activas</h2><div class="reward-redemptions">${activeBenefits.map((item) => `<article><div><strong>${e(item.name)}</strong><small>${e(item.code)} · ${e(rewardStatusName[item.status] || item.status)}${item.expires_at ? ` · vence ${date(item.expires_at)}` : ""}</small></div><div class="row wrap"><span class="badge ${item.status === "requested" ? "pending" : ""}">${e(rewardStatusName[item.status] || item.status)}</span><button class="btn secondary" data-view-coupon="${e(item.id)}">${item.status === "requested" ? "Ver solicitud" : "Ver cupón"} ${I("barcode")}</button></div></article>`).join("")}</div></section>` : ""}<section class="section-gap"><div class="row between wrap reward-heading"><div><h2>${driver ? "Beneficios para tu unidad y tu trabajo" : "Elige tu próxima recompensa"}</h2><p>${driver ? "Los requisitos se revisan al canjear: actividad, ingresos, rating e incidentes recientes." : "Tus puntos no vencen. Los cupones de viaje quedan guardados hasta que decidas usarlos."}</p></div><span class="badge neutral">${catalog.filter((reward) => reward.active).length} beneficios activos</span></div><div class="reward-catalog">${catalog.map((reward) => rewardCard(reward, wallet, systemEnabled)).join("") || '<div class="empty"><p>El catálogo está temporalmente pausado.</p></div>'}</div></section><section class="panel section-gap"><h2>Cómo sumas</h2><div class="grid3 reward-rules">${driver ? `<div>${I("route")}<strong>12 puntos base</strong><p>Por cada viaje completado, más un bono gradual según el ingreso del servicio.</p></div><div>${I("star")}<strong>Hasta 8 puntos extra</strong><p>Las calificaciones de cuatro y cinco estrellas reconocen la calidad del servicio.</p></div><div>${I("shield-check")}<strong>Historial confiable</strong><p>Los mejores beneficios requieren rating alto y no presentar incidentes recientes.</p></div>` : `<div>${I("route")}<strong>10 puntos</strong><p>Por cada viaje completado.</p></div><div>${I("star")}<strong>2 puntos</strong><p>Al evaluar el viaje y ayudar a cuidar la comunidad.</p></div><div>${I("car-front")}<strong>Viaje gratis</strong><p>Cada 15 viajes se agrega automáticamente un viaje local Básico que puedes acumular.</p></div>`}</div></section><details class="panel section-gap reward-history"><summary>Ver movimientos de puntos</summary>${entries.length ? entries.map((entry) => `<div class="receipt-row"><div><strong>${e(entry.description || entry.entry_type)}</strong><small>${date(entry.created_at)}</small></div><strong class="${entry.points < 0 ? "negative-points" : "positive-points"}">${entry.points > 0 ? "+" : ""}${entry.points}</strong></div>`).join("") : '<p class="muted">Tus movimientos aparecerán después del primer viaje o canje.</p>'}</details>`,
    driver ? "Tu buen servicio se recompensa." : "Viaja, suma y disfruta.",
    driver ? "Beneficios graduales para cuidar tu unidad y reconocer tu desempeño." : "Puntos Viajeros y recompensas que puedes guardar para cuando las necesites.",
  );
  $$('[data-view-coupon]').forEach((item) => item.onclick = () => {
    const redemption = redemptions.find((entry) => entry.id === item.dataset.viewCoupon);
    if (redemption) openRewardCoupon(redemption);
  });
  $$('[data-redeem]').forEach((item) => item.onclick = () => {
    const reward = catalog.find((entry) => entry.id === item.dataset.redeem);
    openModal(
      "Confirmar canje",
      `<div class="reward-confirm">${I(reward.icon || "gift")}<h3>${e(reward.name)}</h3><p>${e(reward.description)}</p><div class="receipt-row total"><span>Costo</span><strong>${reward.points_cost} puntos</strong></div><p class="hint">${["fare_discount_fixed", "fare_discount_percent", "ride_amenity"].includes(reward.kind) ? "La recompensa quedará guardada para elegirla al confirmar un próximo viaje." : "Operaciones revisará el canje y te avisará cuando el beneficio esté listo."}</p><button class="btn wide" id="confirm-reward">Canjear recompensa ${I("arrow-right")}</button></div>`,
    );
    $("#confirm-reward").onclick = () => run(async () => {
      await rpc("redeem_reward", { reward_id: reward.id });
      closeModal();
      S.data = await rpc("dashboard");
      rewards();
      notify("Recompensa canjeada y registrada.");
    });
  });
}
function maybeShowRewardPromo() {
  if (!S.profile || S.profile.role === "admin" || modal.open || !S.data.reward_wallet || S.data.marketing?.rewards_enabled === false) return;
  const wallet = S.data.reward_wallet;
  const today = new Date().toISOString().slice(0, 10);
  const key = `yavoi-reward-promo:${S.user.id}:${today}`;
  try {
    if (sessionStorage.getItem(key)) return;
    sessionStorage.setItem(key, "shown");
  } catch {}
  const catalog = (wallet.catalog || []).filter((reward) => reward.active && !reward.automatic);
  const nextReward = catalog
    .filter((reward) => reward.points_cost > Number(wallet.available_points || 0))
    .sort((a, b) => a.points_cost - b.points_cost)[0] || catalog[0];
  const driver = S.profile.role === "driver";
  const freeRides = (wallet.redemptions || []).filter(
    (reward) => reward.kind === "free_local_trip" && reward.status === "available",
  ).length;
  openModal(
    driver ? "Tu desempeño también suma" : "Tus Puntos Viajeros te esperan",
    `<div class="reward-welcome">${I(driver ? "star" : "gift")}<div><span class="badge">Nivel ${e(wallet.level)}</span><h3>${wallet.available_points} puntos disponibles</h3><p>${driver ? `${wallet.trip_count} viajes · ${wallet.rating ? `${decimal(wallet.rating)}/5 de rating` : "completa tus primeros viajes para formar tu rating"}.` : `${wallet.trip_count} viajes completados · ${freeRides} viajes locales gratis guardados.`}</p></div></div>${nextReward ? `<div class="next-reward"><small>PRÓXIMA META</small><strong>${e(nextReward.name)}</strong><p>${Number(wallet.available_points || 0) >= nextReward.points_cost ? "Ya tienes puntos para solicitarla." : `Te faltan ${nextReward.points_cost - Number(wallet.available_points || 0)} puntos para alcanzarla.`}</p></div>` : ""}<button class="btn wide" id="open-rewards">Ver mis recompensas ${I("arrow-right")}</button>`,
  );
  $("#open-rewards").onclick = () => {
    closeModal();
    location.hash = "rewards";
  };
}
function campaignImageUrl(path) {
  if (!path) return "";
  return db.storage.from("yavoi-marketing").getPublicUrl(path).data.publicUrl || "";
}
function maybeShowCampaignPromo() {
  if (!S.profile || S.profile.role === "admin" || modal.open || S.data.marketing?.advertising_enabled === false) return false;
  const campaigns = S.data.marketing?.campaigns || [];
  const campaign = campaigns.find((item) => {
    try { return !sessionStorage.getItem(`yavoi-campaign:${S.user.id}:${item.id}`); }
    catch { return true; }
  });
  if (!campaign) return false;
  try { sessionStorage.setItem(`yavoi-campaign:${S.user.id}:${campaign.id}`, "shown"); } catch {}
  const image = campaignImageUrl(campaign.image_path);
  openModal(
    campaign.discount_label || "Beneficio Yavoi!",
    `<article class="campaign-modal">${image ? `<img src="${e(image)}" alt="Promoción de ${e(campaign.advertiser_name)}">` : `<div class="campaign-placeholder">${I("store")}</div>`}<div class="campaign-modal-copy"><span class="badge">${e(campaign.advertiser_name)}</span><h3>${e(campaign.title)}</h3><p>${e(campaign.description)}</p><small>Promoción vigente hasta ${date(campaign.ends_at)}. Consulta condiciones con el negocio participante.</small></div><div class="campaign-actions">${campaign.cta_url && campaign.cta_label ? `<a class="btn wide" href="${e(campaign.cta_url)}" target="_blank" rel="noopener noreferrer">${e(campaign.cta_label)} ${I("external-link")}</a>` : ""}<button class="btn secondary wide" id="campaign-rewards">Ver mis recompensas ${I("gift")}</button></div></article>`,
  );
  $("#campaign-rewards").onclick = () => { closeModal(); location.hash = "rewards"; };
  return true;
}
function maybeShowEngagementPromo() {
  if (!maybeShowCampaignPromo()) maybeShowRewardPromo();
}
async function upload(file, bucket) {
  if (!file || !file.size) return null;
  const types =
    bucket === "yavoi-documents" || bucket === "yavoi-payment-proofs"
      ? ["application/pdf", "image/jpeg", "image/png"]
      : ["image/jpeg", "image/png", "image/webp"];
  if (!types.includes(file.type)) throw Error("Elige un archivo del formato permitido.");
  const maxMb = bucket === "yavoi-documents" || bucket === "yavoi-payment-proofs" ? 5 : bucket === "yavoi-marketing" ? 4 : 2;
  if (file.size > maxMb * 1024 * 1024)
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
  const safetyAccepted =
    profile.passenger_policy_accepted_at &&
    profile.passenger_policy_version === PASSENGER_POLICY_VERSION;
  const privacyAccepted =
    profile.privacy_policy_accepted_at &&
    profile.privacy_policy_version === PRIVACY_POLICY_VERSION;
  const termsAccepted =
    profile.terms_accepted_at && profile.terms_version === TERMS_VERSION;
  const complete = safetyAccepted && privacyAccepted && termsAccepted;
  return `<section class="passenger-policy"><div class="row between"><div><div class="eyebrow">ACUERDOS DE LA CUENTA</div><h3>Seguridad, privacidad y términos</h3></div><span class="badge ${complete ? "" : "pending"}">${complete ? "Aceptados" : "Pendientes"}</span></div><details ${safetyAccepted ? "" : "open"}><summary>Políticas de seguridad para viajar</summary><div class="policy-copy"><p>Al viajar, cada pasajero debe:</p><ul><li>Usar cinturón de seguridad durante todo el trayecto y asegurar correctamente a menores de edad.</li><li>Mantener limpia la unidad y responder por daños causados de forma intencional o negligente.</li><li>No fumar ni vapear, y no consumir alcohol, drogas, estupefacientes u otras sustancias dentro del vehículo.</li><li>No portar armas, materiales peligrosos ni objetos que pongan en riesgo a otras personas.</li><li>Tratar con respeto al conductor y a los acompañantes; no se permite acoso, discriminación, amenazas ni violencia.</li><li>Respetar la capacidad de la categoría, informar equipaje o carga especial y seguir las indicaciones de seguridad.</li><li>No distraer al conductor, interferir con la conducción ni pedir maniobras contrarias a la ley.</li><li>Estar listo en el punto acordado y verificar la placa, unidad y conductor antes de abordar.</li><li>Cancelar tan pronto como sea posible. No hay cargo antes de una asignación ni durante los primeros 2 minutos después de que un conductor acepta. Después se aplica una cuota de $25; si la unidad ya llegó, la cuota es de $35. El importe siempre se muestra antes de confirmar.</li><li>Una cancelación del conductor u Operaciones no genera cuota al pasajero. En pagos electrónicos se devuelve el saldo después de descontar la cuota aplicable; en efectivo la cuota queda registrada hasta su conciliación.</li></ul><p>El conductor puede reportar incumplimientos. Ante una conducta grave o un riesgo inmediato, puede detenerse en un lugar seguro, cancelar el servicio y solicitar el descenso. Yavoi! puede revisar cancelaciones reiteradas, investigar el caso, restringir la cuenta y compartir información con autoridades cuando exista obligación legal. En una emergencia llama al 911.</p></div></details><label class="check policy-accept"><input name="accept_passenger_policy" type="checkbox" ${safetyAccepted ? "checked" : ""} required>He leído y acepto las Políticas de Seguridad y Cancelación, versión ${PASSENGER_POLICY_VERSION}.</label><details ${privacyAccepted ? "" : "open"}><summary>Política de Privacidad y tratamiento de datos</summary><div class="policy-copy"><p>Yavoi! trata los datos necesarios para crear y proteger tu cuenta, cotizar y prestar viajes, procesar pagos, brindar soporte, prevenir fraude y cumplir obligaciones legales.</p><ul><li>Podemos tratar nombre, teléfono, correo, fotografía, contacto de emergencia, ubicaciones, rutas, mensajes del viaje, pagos tokenizados, valoraciones, reportes y datos técnicos de seguridad.</li><li>Durante un servicio compartimos con el conductor sólo la información necesaria para identificarte, recogerte, atender tus indicaciones y completar el viaje.</li><li>La ubicación se utiliza para cotización, asignación, seguimiento y seguridad. Los datos de tarjeta son procesados por el proveedor de pagos; Yavoi! no almacena número completo ni CVV.</li><li>Conservamos registros durante el tiempo necesario para operación, aclaraciones, seguridad y obligaciones aplicables. Aplicamos controles de acceso y trazabilidad.</li><li>Puedes solicitar acceso, rectificación, cancelación u oposición y consultar cambios a este aviso mediante admin.yavoi@gmail.com mientras se habilita el canal oficial.</li></ul><p>No vendemos tus datos personales. Una solicitud legal válida, emergencia o investigación de seguridad puede requerir conservar o compartir información con autoridades competentes.</p></div></details><label class="check policy-accept"><input name="accept_privacy_policy" type="checkbox" ${privacyAccepted ? "checked" : ""} required>He leído y acepto la Política de Privacidad, versión ${PRIVACY_POLICY_VERSION}.</label><details ${termsAccepted ? "" : "open"}><summary>Términos de Servicio</summary><div class="policy-copy"><p>Al utilizar Yavoi! confirmas que proporcionarás información verdadera, protegerás tu acceso y usarás la plataforma únicamente para solicitar y recibir servicios permitidos.</p><ul><li>Las tarifas, categoría, forma de pago, propina y condiciones se muestran antes de confirmar. Los estimados pueden actualizarse si cambia la ruta o disponibilidad antes de solicitar.</li><li>Debes verificar conductor, fotografía, vehículo y placas antes de abordar, comunicar necesidades especiales y respetar las reglas de seguridad.</li><li>Antes de cancelar se presenta la cuota y el reembolso calculados por el servidor. Las cancelaciones previas a la asignación y las realizadas dentro de la gracia de 2 minutos son gratuitas; después cuestan $25 y, cuando la unidad ya llegó, $35.</li><li>Los viajes, cancelaciones, responsables, motivos, mensajes, pagos, valoraciones y reportes quedan ligados a la cuenta para atención y trazabilidad.</li><li>Yavoi! puede limitar temporalmente una cuenta por datos falsos, fraude, riesgo, cancelaciones abusivas, incumplimientos reiterados o investigación de incidentes.</li><li>Las promociones y recompensas tienen vigencia, disponibilidad y condiciones propias visibles en la aplicación.</li></ul><p>El uso continuado requiere aceptar la versión vigente. Puedes dejar de utilizar el servicio y solicitar atención sobre tu cuenta mediante admin.yavoi@gmail.com.</p></div></details><label class="check policy-accept"><input name="accept_terms" type="checkbox" ${termsAccepted ? "checked" : ""} required>He leído y acepto los Términos de Servicio, versión ${TERMS_VERSION}.</label></section>`;
}
function documentField(name, title, path, note = "") {
  return `<label class="document-upload"><span>${e(title)}</span><input name="${name}" type="file" accept="application/pdf,image/jpeg,image/png"><small>${path ? "Documento recibido. Puedes reemplazarlo." : "Pendiente de cargar"}${note ? ` · ${e(note)}` : ""}</small></label>`;
}
function vehiclePhotoField(path) {
  return `<label class="document-upload vehicle-photo-upload"><span>Fotografía frontal del vehículo con placa visible</span><input name="vehicle_front_file" type="file" accept="image/jpeg,image/png,image/webp"><small>${path ? "Fotografía recibida. Puedes reemplazarla." : "Pendiente de cargar"} · Toma la imagen de frente, con buena luz y la placa completamente legible.</small></label>`;
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
    ? `<details class="profile-section dossier-details" ${dossier.percent < 100 ? "open" : ""}><summary><span>${I("car-front")}<strong>Mi unidad y documentos</strong></span><span class="badge ${d.approved ? "" : "pending"}">${d.approved ? "Aprobado" : dossier.percent === 100 ? "100% completo" : `${dossier.percent}% completo`}</span></summary><div class="profile-section-body">${driverProgressMarkup(p, d)}<p class="hint">Al modificar el expediente la autorización anterior se pausa hasta una nueva revisión. Los documentos son privados y sólo el conductor y Operaciones pueden consultarlos.</p>${d.review_note ? `<p class="hint">Revisión: ${e(d.review_note)}</p>` : ""}<form id="vehicle-form"><fieldset ${formDisabled}><h3>Datos de la unidad</h3><div class="grid2"><label>Marca<input name="vehicle_make" required minlength="2" maxlength="50" value="${e(d.vehicle_make)}" placeholder="Nissan"></label><label>Modelo<input name="vehicle_model" required minlength="1" maxlength="50" value="${e(d.vehicle_model)}" placeholder="Versa"></label><label>Año<input name="vehicle_year" type="number" min="1990" max="${new Date().getFullYear() + 1}" required value="${e(d.vehicle_year || "")}"></label><label>Color<input name="vehicle_color" required minlength="3" maxlength="40" value="${e(d.vehicle_color)}" placeholder="Gris"></label><label>Placas<input name="plate" required minlength="5" maxlength="20" value="${e(d.plate)}"></label><label>Categoría<select name="category">${S.categories.map((c) => `<option value="${c.id}" ${d.category === c.id ? "selected" : ""}>${e(c.name)}</option>`).join("")}</select></label><label>Número de licencia<input name="license_number" required maxlength="50" value="${e(d.license_number)}"></label><label>Vencimiento de licencia<input name="license_expires" type="date" required value="${e(d.license_expires)}"></label><label>Vencimiento de seguro<input name="insurance_expires" type="date" required value="${e(d.insurance_expires)}"></label></div><h3 class="section-gap">Documentos privados</h3><div class="driver-documents">${vehiclePhotoField(d.vehicle_front_path)}${documentField("license_file", "Licencia de conducir", d.license_path)}${documentField("insurance_file", "Póliza de seguro", d.insurance_path)}${documentField("criminal_record_file", "Carta de no antecedentes penales", d.criminal_record_path, "carga el documento oficial vigente")}${documentField("policy_commitment_file", "Carta de compromiso y políticas Yavoi! firmada", d.policy_commitment_path)}${documentField("traffic_law_commitment_file", "Carta de aceptación de obligaciones viales firmada", d.traffic_law_commitment_path)}</div><div class="document-templates"><div>${I("file-down")}<span><strong>Plantillas para firma</strong><small>Descarga, completa, firma y carga el documento entero.</small></span></div><a class="btn secondary" href="/documents/carta-compromiso-politicas-yavoi.pdf" download>Políticas Yavoi! ${I("download")}</a><a class="btn secondary" href="/documents/carta-aceptacion-vialidad-chihuahua.pdf" download>Obligaciones viales ${I("download")}</a><a class="link" href="https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf" target="_blank" rel="noopener noreferrer">Consultar ley oficial ${I("external-link")}</a></div><label class="check"><input type="checkbox" name="advertising_interest" ${d.advertising_interest ? "checked" : ""}>Me interesa participar en convenios de publicidad</label><button type="submit" class="btn">Guardar y enviar expediente ${I("shield-check")}</button></fieldset></form></div></details>`
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
        accept_privacy_policy: v.accept_privacy_policy === "on",
        privacy_policy_version: PRIVACY_POLICY_VERSION,
        accept_terms: v.accept_terms === "on",
        terms_version: TERMS_VERSION,
      });
      await loadSession();
      notify("Perfil actualizado.");
    });
    bindForm("#vehicle-form", async (v, f) => {
      const [vehicleFront, license, insurance, criminalRecord, policyCommitment, trafficLawCommitment] = await Promise.all([
        upload(f.elements.vehicle_front_file.files[0], "yavoi-vehicle-photos"),
        upload(f.elements.license_file.files[0], "yavoi-documents"),
        upload(f.elements.insurance_file.files[0], "yavoi-documents"),
        upload(f.elements.criminal_record_file.files[0], "yavoi-documents"),
        upload(f.elements.policy_commitment_file.files[0], "yavoi-documents"),
        upload(f.elements.traffic_law_commitment_file.files[0], "yavoi-documents"),
      ]);
      await rpc("driver_profile", {
        ...v,
        vehicle_front_file: undefined,
        license_file: undefined,
        insurance_file: undefined,
        criminal_record_file: undefined,
        policy_commitment_file: undefined,
        traffic_law_commitment_file: undefined,
        ...(vehicleFront ? { vehicle_front_path: vehicleFront } : {}),
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
        privacy_policy_accepted_at: values.accept_privacy_policy === "on" ? new Date().toISOString() : null,
        privacy_policy_version: values.accept_privacy_policy === "on" ? PRIVACY_POLICY_VERSION : null,
        terms_accepted_at: values.accept_terms === "on" ? new Date().toISOString() : null,
        terms_version: values.accept_terms === "on" ? TERMS_VERSION : null,
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
        vehicle_front_path: "vehicle_front_file",
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
function localDateTime(value) {
  const dateValue = value ? new Date(value) : new Date();
  return new Date(dateValue.getTime() - dateValue.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
}
function campaignStatus(campaign) {
  const now = Date.now();
  if (!campaign.active) return ["Desactivada", "neutral"];
  if (Date.parse(campaign.ends_at) <= now) return ["Finalizada", "cancelled"];
  if (Date.parse(campaign.starts_at) > now) return ["Programada", "pending"];
  return ["Vigente", ""];
}
function openCampaignEditor(campaign = null) {
  const starts = campaign?.starts_at || new Date().toISOString();
  const ends = campaign?.ends_at || new Date(Date.now() + 30 * 86400000).toISOString();
  openModal(
    campaign ? "Editar promoción" : "Nueva promoción",
    `<form id="campaign-form"><label>Negocio o anunciante<input name="advertiser_name" required minlength="2" maxlength="100" value="${e(campaign?.advertiser_name || "")}" placeholder="Nombre del comercio"></label><label>Título de la promoción<input name="title" required minlength="3" maxlength="100" value="${e(campaign?.title || "")}" placeholder="Beneficio para la comunidad Yavoi!"></label><label>Descuento o beneficio destacado<input name="discount_label" maxlength="100" value="${e(campaign?.discount_label || "")}" placeholder="Ejemplo: 15% de descuento"></label><label>Descripción y condiciones<textarea name="description" required minlength="5" maxlength="700">${e(campaign?.description || "")}</textarea></label><div class="grid2"><label>Audiencia<select name="audience"><option value="all" ${campaign?.audience === "all" || !campaign ? "selected" : ""}>Todos</option><option value="passenger" ${campaign?.audience === "passenger" ? "selected" : ""}>Pasajeros</option><option value="driver" ${campaign?.audience === "driver" ? "selected" : ""}>Conductores</option></select></label><label>Prioridad<input name="priority" type="number" min="0" max="1000" value="${e(campaign?.priority ?? 100)}"></label><label>Inicio<input name="starts_at" type="datetime-local" required value="${localDateTime(starts)}"></label><label>Fin<input name="ends_at" type="datetime-local" required value="${localDateTime(ends)}"></label></div><label>Fotografía · JPG, PNG o WebP, hasta 4 MB<input name="image" type="file" accept="image/jpeg,image/png,image/webp"></label>${campaign?.image_path ? '<p class="hint">La fotografía actual se conserva si no eliges una nueva.</p>' : ""}<div class="grid2"><label>Texto del botón<input name="cta_label" maxlength="50" value="${e(campaign?.cta_label || "")}" placeholder="Conocer promoción"></label><label>Enlace seguro del negocio<input name="cta_url" type="url" maxlength="500" value="${e(campaign?.cta_url || "")}" placeholder="https://..."></label></div><label class="check"><input name="active" type="checkbox" ${campaign?.active === false ? "" : "checked"}>Publicar cuando se encuentre dentro de su vigencia</label><button class="btn wide" type="submit">Guardar promoción ${I("check")}</button></form>`,
  );
  bindForm("#campaign-form", async (values, form) => {
    const imagePath = await upload(form.elements.image.files[0], "yavoi-marketing");
    await rpc("upsert_campaign", {
      id: campaign?.id || null,
      advertiser_name: values.advertiser_name,
      title: values.title,
      discount_label: values.discount_label,
      description: values.description,
      audience: values.audience,
      priority: Number(values.priority),
      starts_at: new Date(values.starts_at).toISOString(),
      ends_at: new Date(values.ends_at).toISOString(),
      image_path: imagePath || campaign?.image_path || null,
      cta_label: values.cta_label,
      cta_url: values.cta_url,
      active: values.active === "on",
    });
    closeModal();
    await refreshPage();
    notify("Promoción guardada y registrada en Auditoría.");
  });
}
const rewardKindNames = {
  fare_discount_fixed: "Descuento fijo para viaje",
  fare_discount_percent: "Descuento porcentual para viaje",
  free_local_trip: "Viaje local gratuito",
  ride_amenity: "Amenidad durante el viaje",
  partner_coupon: "Cupón de comercio",
  driver_benefit: "Beneficio para conductor",
};
const rewardDeliveryNames = {
  digital_coupon: "Cupón digital inmediato",
  trip: "Aplicable al confirmar viaje",
  operations: "Entrega coordinada por Operaciones",
};
function openRewardEditor(reward = null) {
  const categoryOptions = S.categories.map((category) => `<option value="${e(category.id)}" ${reward?.eligible_category === category.id ? "selected" : ""}>Yavoi! ${e(category.name)}</option>`).join("");
  openModal(
    reward ? "Editar recompensa" : "Nueva recompensa",
    `<form id="reward-editor" class="reward-editor"><div class="grid2"><label>Dirigida a<select name="audience"><option value="passenger" ${reward?.audience !== "driver" ? "selected" : ""}>Pasajeros</option><option value="driver" ${reward?.audience === "driver" ? "selected" : ""}>Conductores</option></select></label><label>Forma de entrega<select name="delivery_mode">${Object.entries(rewardDeliveryNames).map(([value, label]) => `<option value="${value}" ${reward?.delivery_mode === value ? "selected" : ""}>${label}</option>`).join("")}</select></label></div><label>Nombre del beneficio<input name="name" required minlength="3" maxlength="100" value="${e(reward?.name || "")}" placeholder="Ej. 15% en tu próxima compra"></label><label>Empresa o proveedor<input name="partner_name" maxlength="100" value="${e(reward?.partner_name || "")}" placeholder="Yavoi! o nombre del negocio"></label><label>Descripción<textarea name="description" required minlength="5" maxlength="500">${e(reward?.description || "")}</textarea></label><label>Condiciones visibles en el cupón<textarea name="terms" maxlength="1000" placeholder="Vigencia, sucursales, productos participantes y restricciones.">${e(reward?.terms || "")}</textarea></label><label>Imagen o logotipo · JPG, PNG o WebP, hasta 4 MB<input name="image" type="file" accept="image/jpeg,image/png,image/webp"></label>${reward?.image_path ? `<label class="check"><input name="remove_image" type="checkbox">Quitar la imagen actual</label>` : ""}<details class="reward-editor-details" open><summary>Valor, puntos y requisitos</summary><div class="grid2"><label>Tipo<select name="kind">${Object.entries(rewardKindNames).map(([value, label]) => `<option value="${value}" ${reward?.kind === value ? "selected" : ""}>${label}</option>`).join("")}</select></label><label>Costo en puntos<input name="points_cost" type="number" min="0" max="100000" required value="${e(reward?.points_cost ?? 0)}"></label><label>Descuento fijo (MXN)<input name="value_mxn" type="number" min="0" max="10000" step="0.01" value="${reward?.value_cents == null ? "" : Number(reward.value_cents) / 100}"></label><label>Descuento porcentual<input name="value_percent" type="number" min="0" max="100" step="0.01" value="${e(reward?.value_percent ?? "")}"></label><label>Descuento máximo (MXN)<input name="max_discount_mxn" type="number" min="0" max="10000" step="0.01" value="${reward?.max_discount_cents == null ? "" : Number(reward.max_discount_cents) / 100}"></label><label>Categoría requerida<select name="eligible_category"><option value="">Cualquier categoría</option>${categoryOptions}</select></label><label>Viajes mínimos<input name="min_trips" type="number" min="0" value="${e(reward?.min_trips ?? 0)}"></label><label>Rating mínimo<input name="min_rating" type="number" min="1" max="5" step="0.01" value="${e(reward?.min_rating ?? "")}"></label><label>Ingresos mínimos (MXN)<input name="min_income_mxn" type="number" min="0" step="0.01" value="${reward?.min_income_cents ? Number(reward.min_income_cents) / 100 : ""}"></label><label>Incidentes recientes máximos<input name="max_recent_incidents" type="number" min="0" value="${e(reward?.max_recent_incidents ?? "")}"></label><label>Inventario total<input name="total_stock" type="number" min="0" value="${e(reward?.total_stock ?? "")}" placeholder="Vacío = sin límite"></label><label>Vigencia al desbloquear (días)<input name="expires_days" type="number" min="1" max="730" value="${e(reward?.expires_days ?? 180)}"></label><label>Orden de aparición<input name="sort_order" type="number" min="0" max="10000" value="${e(reward?.sort_order ?? 100)}"></label><label>Icono<select name="icon">${["gift","ticket","badge-percent","badge-dollar-sign","car-front","store","cup-soda","sparkles","wrench","crown","snowflake"].map((icon) => `<option value="${icon}" ${reward?.icon === icon ? "selected" : ""}>${icon}</option>`).join("")}</select></label></div><label>Instrucción de entrega<textarea name="fulfillment_note" maxlength="500">${e(reward?.fulfillment_note || "")}</textarea></label><div class="grid2"><label class="check"><input name="automatic" type="checkbox" ${reward?.automatic ? "checked" : ""}>Generación automática por viajes</label><label>Cada cuántos viajes<input name="milestone_every" type="number" min="1" value="${e(reward?.milestone_every ?? "")}"></label></div></details><label class="check"><input name="active" type="checkbox" ${reward?.active === false ? "" : "checked"}>Disponible para desbloquear</label><button class="btn wide" type="submit">Guardar recompensa ${I("check")}</button></form>`,
  );
  bindForm("#reward-editor", async (values, form) => {
    const uploadedImage = await upload(form.elements.image.files[0], "yavoi-marketing");
    const optionalCents = (value) => value === "" || value == null ? null : cents(value);
    await rpc("upsert_reward", {
      id: reward?.id || null,
      audience: values.audience,
      delivery_mode: values.delivery_mode,
      name: values.name,
      partner_name: values.partner_name,
      description: values.description,
      terms: values.terms,
      image_path: values.remove_image === "on" ? null : uploadedImage || reward?.image_path || null,
      kind: values.kind,
      icon: values.icon,
      points_cost: Number(values.points_cost),
      value_cents: optionalCents(values.value_mxn),
      value_percent: values.value_percent === "" ? null : Number(values.value_percent),
      max_discount_cents: optionalCents(values.max_discount_mxn),
      eligible_category: values.eligible_category || null,
      min_trips: Number(values.min_trips || 0),
      min_rating: values.min_rating === "" ? null : Number(values.min_rating),
      min_income_cents: optionalCents(values.min_income_mxn) || 0,
      max_recent_incidents: values.max_recent_incidents === "" ? null : Number(values.max_recent_incidents),
      total_stock: values.total_stock === "" ? null : Number(values.total_stock),
      expires_days: Number(values.expires_days),
      sort_order: Number(values.sort_order),
      fulfillment_note: values.fulfillment_note,
      automatic: values.automatic === "on",
      milestone_every: values.milestone_every === "" ? null : Number(values.milestone_every),
      active: values.active === "on",
    });
    closeModal();
    await refreshPage();
    notify("Recompensa guardada y registrada en Auditoría.");
  });
}
function marketingView() {
  const marketing = S.data.marketing || { rewards_enabled: true, advertising_enabled: true, campaigns: [], reward_catalog: [] };
  const campaigns = marketing.campaigns || [];
  const rewardsCatalog = marketing.reward_catalog || [];
  const audienceLabel = { all: "Todos", passenger: "Pasajeros", driver: "Conductores" };
  const campaignCards = campaigns.map((campaign) => {
    const [status, kind] = campaignStatus(campaign);
    const image = campaignImageUrl(campaign.image_path);
    return `<article class="campaign-card">${image ? `<img src="${e(image)}" alt="${e(campaign.title)}">` : `<div class="campaign-card-placeholder">${I("image")}</div>`}<div class="campaign-card-copy"><div class="row between wrap"><span class="badge ${kind}">${e(status)}</span><small>${e(audienceLabel[campaign.audience] || campaign.audience)}</small></div><h3>${e(campaign.title)}</h3><strong>${e(campaign.advertiser_name)}</strong><p>${e(campaign.description)}</p><small>${date(campaign.starts_at)} → ${date(campaign.ends_at)}</small></div><div class="campaign-card-actions"><button class="btn secondary" data-edit-campaign="${e(campaign.id)}">Editar ${I("pencil")}</button><button class="btn ${campaign.active ? "danger" : "secondary"}" data-toggle-campaign="${e(campaign.id)}" data-active="${campaign.active ? "false" : "true"}">${campaign.active ? "Desactivar" : "Activar"}</button></div></article>`;
  }).join("");
  const rewardCards = rewardsCatalog.map((reward) => { const image = rewardImageUrl(reward.image_path); return `<article class="marketing-reward" data-reward-audience="${e(reward.audience)}">${image ? `<img class="marketing-reward-image" src="${e(image)}" alt="${e(reward.partner_name || reward.name)}">` : `<div class="reward-icon">${I(reward.icon || "gift")}</div>`}<div><div class="row wrap"><strong>${e(reward.name)}</strong><span class="badge neutral">${reward.audience === "driver" ? "Conductores" : "Pasajeros"}</span><span class="badge ${reward.active ? "" : "pending"}">${reward.active ? "Activa" : "Pausada"}</span></div><p>${e(reward.description)}</p><small>${reward.points_cost} puntos · ${e(reward.partner_name || "Yavoi!")} · ${e(rewardDeliveryNames[reward.delivery_mode] || "Operaciones")}</small></div><div class="marketing-reward-actions"><button class="btn secondary" data-edit-reward="${e(reward.id)}">Editar ${I("pencil")}</button><button class="btn ${reward.active ? "danger" : "secondary"}" data-toggle-reward="${e(reward.id)}" data-active="${reward.active ? "false" : "true"}">${reward.active ? "Desactivar" : "Activar"}</button></div></article>`; }).join("");
  shell(
    `<section class="panel marketing-controls"><div class="row between wrap"><div><h2>Controles generales</h2><p>Pausa o reactiva cada sistema para todos los perfiles. Los puntos y registros existentes siempre se conservan.</p></div><span class="badge neutral">Cambios protegidos con verificación en dos pasos</span></div><form id="marketing-settings" class="marketing-switches"><label class="marketing-switch"><input name="rewards_enabled" type="checkbox" ${marketing.rewards_enabled ? "checked" : ""}><span>${I("gift")}<strong>Sistema de Recompensas</strong><small>Acumulación, metas y canjes.</small></span></label><label class="marketing-switch"><input name="advertising_enabled" type="checkbox" ${marketing.advertising_enabled ? "checked" : ""}><span>${I("megaphone")}<strong>Publicidad y promociones</strong><small>Ventanas vigentes para usuarios y conductores.</small></span></label><button class="btn" type="submit">Guardar controles ${I("shield-check")}</button></form></section><section class="panel section-gap"><div class="row between wrap"><div><h2>Publicidad y descuentos</h2><p>Programa fotografías, vigencia, audiencia y enlace de cada negocio.</p></div><button class="btn" id="new-campaign">Nueva promoción ${I("plus")}</button></div><div class="campaign-grid">${campaignCards || '<div class="empty"><p>No hay promociones creadas. Agrega la primera cuando tengas un convenio vigente.</p></div>'}</div></section><section class="panel section-gap"><div class="row between wrap"><div><h2>Catálogo de recompensas</h2><p>Crea, modifica y publica beneficios con imagen, requisitos, inventario y forma de entrega.</p></div><div class="row wrap"><span class="badge ${marketing.rewards_enabled ? "" : "pending"}">${marketing.rewards_enabled ? "Sistema activo" : "Sistema pausado"}</span><button class="btn" id="new-reward">Nueva recompensa ${I("plus")}</button></div></div><div class="reward-catalog-toolbar"><label>Mostrar catálogo<select id="reward-audience-filter"><option value="all">Todos</option><option value="passenger">Pasajeros</option><option value="driver">Conductores</option></select></label><span id="reward-filter-count">${rewardsCatalog.length} conceptos</span></div><div class="marketing-reward-list">${rewardCards || '<div class="empty"><p>No hay recompensas en este catálogo.</p></div>'}</div></section>`,
    "Recompensas y publicidad",
    "Controla beneficios, campañas y promociones desde un solo módulo.",
  );
  bindForm("#marketing-settings", async (values) => {
    await rpc("set_marketing_settings", { rewards_enabled: values.rewards_enabled === "on", advertising_enabled: values.advertising_enabled === "on" });
    await refreshPage();
    notify("Controles generales actualizados.");
  });
  $("#new-campaign").onclick = () => openCampaignEditor();
  $("#new-reward").onclick = () => openRewardEditor();
  $("#reward-audience-filter").onchange = (event) => {
    const audience = event.target.value;
    let visible = 0;
    $$('[data-reward-audience]').forEach((card) => {
      const show = audience === "all" || card.dataset.rewardAudience === audience;
      card.classList.toggle("hidden", !show);
      if (show) visible += 1;
    });
    $("#reward-filter-count").textContent = `${visible} concepto${visible === 1 ? "" : "s"}`;
  };
  $$('[data-edit-campaign]').forEach((item) => item.onclick = () => openCampaignEditor(campaigns.find((campaign) => campaign.id === item.dataset.editCampaign)));
  $$('[data-edit-reward]').forEach((item) => item.onclick = () => openRewardEditor(rewardsCatalog.find((reward) => reward.id === item.dataset.editReward)));
  $$('[data-toggle-campaign]').forEach((item) => item.onclick = () => run(async () => {
    await rpc("set_campaign_active", { campaign_id: item.dataset.toggleCampaign, active: item.dataset.active === "true" });
    await refreshPage();
  }));
  $$('[data-toggle-reward]').forEach((item) => item.onclick = () => run(async () => {
    await rpc("set_reward_active", { reward_id: item.dataset.toggleReward, active: item.dataset.active === "true" });
    await refreshPage();
  }));
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
function operationsCards(units = []) {
  return units.length
    ? units.map((unit) => {
      const [status, kind] = operationsUnitStatus(unit);
      return `<article class="fleet-unit" data-unit-id="${e(unit.driver_id)}">${avatar(unit.full_name, unit.avatar_path)}<div><div class="row wrap"><strong>${e(unit.full_name)}</strong><span class="badge ${kind}">${e(status)}</span></div><p>${e([unit.vehicle_color, unit.vehicle_make, unit.vehicle_model, unit.vehicle_year].filter(Boolean).join(" ") || unit.vehicle || "Unidad por completar")} · ${e(unit.plate || "Sin placas")}</p><small data-unit-signal>${unit.heartbeat_at ? `Última señal ${date(unit.heartbeat_at)}` : "Sin señal GPS registrada"}</small>${unit.trip_id ? `<a class="link" href="#trip/${e(unit.trip_id)}">${e(unit.passenger_name || "Pasajero")} · ${e(unit.origin)} → ${e(unit.destination)} · ${money(unit.total_cents || unit.fare_cents)}</a>` : ""}</div></article>`;
    }).join("")
    : '<div class="empty"><p>Aún no hay unidades registradas.</p></div>';
}
function operationsListSignature(units = []) {
  return JSON.stringify(units.map((unit) => [unit.driver_id, unit.full_name, unit.avatar_path, unit.vehicle, unit.vehicle_make, unit.vehicle_model, unit.vehicle_year, unit.vehicle_color, unit.plate, unit.category, unit.online, unit.presence_fresh, unit.trip_id, unit.trip_status, unit.passenger_name, unit.origin, unit.destination, unit.total_cents, unit.fare_cents]));
}
function updateOperationsList(units = []) {
  const list = $("#operations-unit-list");
  if (!list) return;
  const signature = operationsListSignature(units);
  if (signature !== S.opsListSignature) {
    list.innerHTML = operationsCards(units);
    S.opsListSignature = signature;
    iconsNow();
    applyOperationsSearch();
    return;
  }
  units.forEach((unit) => {
    const signal = $(`[data-unit-id="${CSS.escape(unit.driver_id)}"] [data-unit-signal]`, list);
    if (signal) signal.textContent = unit.heartbeat_at ? `Última señal ${date(unit.heartbeat_at)}` : "Sin señal GPS registrada";
  });
}
function updateOperationsMapLayers({ fit = false } = {}) {
  if (!S.map) return;
  const units = S.data.operations_units || [];
  if (!S.mapLiveLayer) S.mapLiveLayer = L.layerGroup().addTo(S.map);
  const connectedBounds = [];
  const activeUnits = new Set();
  units.forEach((unit) => {
    if (!Number.isFinite(Number(unit.lat)) || !Number.isFinite(Number(unit.lng))) return;
    const id = unit.driver_id;
    activeUnits.add(id);
    const point = [Number(unit.lat), Number(unit.lng)];
    const [status] = operationsUnitStatus(unit);
    const livePosition = Boolean(unit.online && unit.presence_fresh);
    if (livePosition) connectedBounds.push(point);
    const tooltip = `<strong>${e(unit.full_name)}</strong><br>${e(status)} · ${e(unit.plate || "Sin placas")}<br>${unit.trip_id ? `${e(unit.passenger_name || "Pasajero")} · ${money(unit.total_cents || unit.fare_cents)}` : e(unit.vehicle || "Unidad registrada")}`;
    let marker = S.opsMarkers.get(id);
    const heading = Math.round(vehicleHeading(marker, unit.heading, point));
    if (!marker) {
      marker = L.marker(point, { icon: vehicleIcon(heading, !!unit.trip_id, unit.category), opacity: livePosition ? 1 : 0.55 })
        .addTo(S.mapLiveLayer)
        .bindTooltip(tooltip, { direction: "top", offset: [0, -18] });
      marker._yavoiHeading = heading;
      S.opsMarkers.set(id, marker);
    } else {
      if (livePosition) marker.setLatLng(point);
      marker.setOpacity(livePosition ? 1 : 0.55).setTooltipContent(tooltip);
      const markerElement = marker.getElement();
      const image = markerElement?.querySelector("img");
      const vehicle = markerElement?.querySelector(".vehicle-icon");
      const category = ["basic", "large", "plus", "commercial", "pickup"].includes(unit.category) ? unit.category : "basic";
      if (image && image.dataset.vehicleCategory !== category) {
        image.src = mapVehicleAsset(category);
        image.dataset.vehicleCategory = category;
      }
      if (livePosition) rotateVehicle(marker, heading);
      if (vehicle) vehicle.classList.toggle("selected", Boolean(unit.trip_id));
    }
    if (unit.trip_id) {
      const popup = `<strong>${e(unit.full_name)}</strong><p>${e(unit.origin)} → ${e(unit.destination)}</p><a href="#trip/${e(unit.trip_id)}">Abrir viaje y conciliación</a>`;
      if (marker.getPopup()) marker.setPopupContent(popup);
      else marker.bindPopup(popup);
    } else if (marker.getPopup()) marker.unbindPopup();
    const history = Array.isArray(unit.route_history) ? unit.route_history : [];
    if (history.length > 1) {
      const route = history.map((item) => [Number(item.lat), Number(item.lng)]);
      if (livePosition) route.forEach((routePoint) => connectedBounds.push(routePoint));
      const polyline = S.opsRoutes.get(id);
      if (polyline) polyline.setLatLngs(route);
      else S.opsRoutes.set(id, L.polyline(route, { color: "#ff6a0a", weight: 5, opacity: 0.78 }).addTo(S.mapLiveLayer));
    } else if (S.opsRoutes.has(id)) {
      S.mapLiveLayer.removeLayer(S.opsRoutes.get(id));
      S.opsRoutes.delete(id);
    }
  });
  [...S.opsMarkers.entries()].forEach(([id, marker]) => {
    if (activeUnits.has(id)) return;
    S.mapLiveLayer.removeLayer(marker);
    S.opsMarkers.delete(id);
  });
  [...S.opsRoutes.entries()].forEach(([id, route]) => {
    if (activeUnits.has(id)) return;
    S.mapLiveLayer.removeLayer(route);
    S.opsRoutes.delete(id);
  });
  const hasLiveUnits = connectedBounds.length > 0;
  if (fit && hasLiveUnits) {
    S.map.fitBounds(connectedBounds, { padding: [55, 55], maxZoom: 15 });
  } else if ((fit && !hasLiveUnits) || (S.opsHadLiveUnits === true && !hasLiveUnits)) {
    S.map.setView(DELICIAS_MAP_CENTER, OPERATIONS_EMPTY_ZOOM);
  }
  S.opsHadLiveUnits = hasLiveUnits;
}
function startOperationsMap() {
  if (!$("#operations-map")) return;
  S.opsHadLiveUnits = null;
  S.map = L.map("operations-map", { zoomControl: true, scrollWheelZoom: true }).setView(
    DELICIAS_MAP_CENTER,
    OPERATIONS_EMPTY_ZOOM,
  );
  L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
  }).addTo(S.map);
  S.map.zoomControl.setPosition("bottomright");
  bindVehicleScale();
  updateOperationsMapLayers({ fit: true });
  setTimeout(() => S.map?.invalidateSize(), 80);
}
async function refreshOperationsMap() {
  S.data = await rpc("dashboard");
  const units = S.data.operations_units || [];
  await Promise.all(units.map((unit) => loadAvatar(unit.avatar_path)));
  if (S.view !== "opsmap" || !S.map) return;
  const live = units.filter((unit) => unit.online && unit.presence_fresh);
  const traveling = live.filter((unit) => unit.trip_id);
  const values = {
    "#ops-registered": units.length,
    "#ops-live": live.length,
    "#ops-available": live.length - traveling.length,
    "#ops-traveling": traveling.length,
  };
  Object.entries(values).forEach(([selector, value]) => {
    const element = $(selector);
    if (element) element.textContent = value;
  });
  updateOperationsList(units);
  updateOperationsMapLayers({ fit: false });
}
async function operationsMapView() {
  const units = S.data.operations_units || [];
  await Promise.all(units.map((unit) => loadAvatar(unit.avatar_path)));
  const live = units.filter((unit) => unit.online && unit.presence_fresh);
  const traveling = live.filter((unit) => unit.trip_id);
  const available = live.filter((unit) => !unit.trip_id);
  shell(
    `<div class="grid4 stats"><div class="stat"><small>Unidades registradas</small><strong id="ops-registered">${units.length}</strong><p>Flotilla total</p></div><div class="stat"><small>Con señal activa</small><strong id="ops-live">${live.length}</strong><p>Actualización menor a 90 segundos</p></div><div class="stat"><small>Disponibles</small><strong id="ops-available">${available.length}</strong><p>Listas para asignación</p></div><div class="stat"><small>En servicio</small><strong id="ops-traveling">${traveling.length}</strong><p>Recorridos visibles en el mapa</p></div></div><div class="operations-map-layout section-gap">${mapFrame("operations-map", "La señal GPS actualiza autos y recorridos sin mover el mapa. Tu zoom y posición se conservan.")}<section class="panel fleet-list"><div class="row between"><h2>Estado de la flotilla</h2>${button("Actualizar", "refresh", "secondary", "refresh-cw")}</div><div id="operations-unit-list">${operationsCards(units)}</div></section></div>`,
    "Mapa de operación en vivo",
    "Disponibilidad, ubicación, viaje activo y recorrido GPS de toda la flotilla.",
  );
  S.opsListSignature = operationsListSignature(units);
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
  const rewardOperations = S.data.reward_operations || { drivers: [], pending: [] };
  const driverRewards = new Map(
    (rewardOperations.drivers || []).map((item) => [item.id, item.rewards || {}]),
  );
  const cards = S.data.drivers.map((d) => {
    const progress = driverDossierStatus(d, d);
    const reward = driverRewards.get(d.id) || {};
    const weeklyBilling = d.billing_mode !== "commission";
    const doc = (path, label) => path ? `<button class="btn secondary" data-document="${e(path)}">${I("file-check")} ${label}</button>` : "";
    return `<details class="offer dossier-card driver-admin-card" data-driver-card="${e(d.id)}"><summary class="driver-admin-summary"><span><strong>${e(d.full_name)}</strong><small>${e(d.vehicle) || "Unidad pendiente"} · ${e(d.plate) || "Sin placas"}</small></span><span class="driver-admin-glance"><small>${reward.rating ? `${decimal(reward.rating)}/5` : "Sin calificación"}</small><small>${Number(reward.trip_count || 0)} viajes</small></span><span class="badge ${d.approved ? "" : "pending"}">${d.approved ? "Aprobado" : progress.percent === 100 ? "Listo para revisar" : `${progress.percent}% completo`}</span>${I("chevron-down")}</summary><div class="driver-admin-body"><div class="fleet-progress"><progress max="100" value="${progress.percent}">${progress.percent}%</progress><small>${progress.completed} de ${progress.total} requisitos${progress.missing.length ? ` · Faltan: ${e(progress.missing.slice(0, 3).join(", "))}${progress.missing.length > 3 ? "…" : ""}` : " · Expediente completo"}</small></div><div class="driver-reward-summary"><span><small>NIVEL RATING</small><strong>${e(reward.level || "Activo")}</strong></span><span><small>PUNTOS</small><strong>${Number(reward.available_points || 0)}</strong></span><span><small>VIAJES</small><strong>${Number(reward.trip_count || 0)}</strong></span><span><small>CALIFICACIÓN</small><strong>${reward.rating ? `${decimal(reward.rating)}/5` : "—"}</strong></span><span><small>INGRESOS</small><strong>${money(reward.income_cents || 0)}</strong></span><span><small>INCIDENTES 90 DÍAS</small><strong>${Number(reward.recent_incidents || 0)}</strong></span></div><div class="driver-billing-row"><div>${I(weeklyBilling ? "calendar-check" : "percent")}<span><small>MODALIDAD COMERCIAL</small><strong>${weeklyBilling ? `Aportación de ${money(d.weekly_fee_cents || 50000)}` : "Comisión por viaje"}</strong><p>Efectivo: ${Number(d.cash_commission_bps || 0) / 100}% · Electrónico: ${Number(d.card_commission_bps || 0) / 100}% para Yavoi!</p></span></div><button class="btn secondary" data-billing="${e(d.id)}">Configurar cobro ${I("settings-2")}</button></div><div class="meta-row"><span>${e(d.phone)}</span><span>Licencia vence: ${e(d.license_expires || "Sin fecha")}</span><span>Seguro vence: ${e(d.insurance_expires || "Sin fecha")}</span></div><div class="document-row">${d.vehicle_front_path ? `<button class="btn secondary" data-vehicle-photo="${e(d.vehicle_front_path)}">${I("car-front")} Frente y placa</button>` : ""}${d.avatar_path ? `<button class="btn secondary" data-photo="${e(d.avatar_path)}">${I("user-round")} Fotografía</button>` : ""}${doc(d.license_path, "Licencia")}${doc(d.insurance_path, "Seguro")}${doc(d.criminal_record_path, "No antecedentes")}${doc(d.policy_commitment_path, "Políticas Yavoi!")}${doc(d.traffic_law_commitment_path, "Obligaciones viales")}<button class="btn" data-review="${e(d.id)}">Revisar autorización ${I("arrow-right")}</button></div>${d.advertising_interest ? "<small>Interesado en convenios de publicidad</small>" : ""}</div></details>`;
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
  const pendingRewards = (rewardOperations.pending || []).map((redemption) =>
    `<article class="reward-operation-card"><div class="reward-icon">${I(redemption.icon || "gift")}</div><div><strong>${e(redemption.name)}</strong><small>${e(redemption.driver_name)} · ${e(redemption.code)} · ${redemption.points_spent} puntos</small><p>${e(redemption.description || "Beneficio solicitado por el conductor.")}</p></div><span class="badge pending">Por entregar</span><div class="row wrap"><button class="btn" data-reward-review="${e(redemption.id)}" data-result="fulfilled">Marcar entregada</button><button class="btn secondary" data-reward-review="${e(redemption.id)}" data-result="cancelled">Cancelar y devolver puntos</button></div></article>`,
  ).join("");
  shell(
    `<section class="panel"><div class="row between"><div><h2>Expedientes de conductores</h2><p>La aprobación sólo se habilita con los 17 requisitos completos y documentos vigentes.</p></div></div><div class="document-templates operations-letter-templates"><div>${I("file-down")}<span><strong>Plantillas vigentes para conductores</strong><small>Consulta o descarga exactamente los documentos que debe firmar cada conductor.</small></span></div><a class="btn secondary" href="/documents/carta-compromiso-politicas-yavoi.pdf" target="_blank" rel="noopener noreferrer">Carta de políticas ${I("external-link")}</a><a class="btn secondary" href="/documents/carta-aceptacion-vialidad-chihuahua.pdf" target="_blank" rel="noopener noreferrer">Carta de obligaciones viales ${I("external-link")}</a><a class="link" href="https://www.congresochihuahua2.gob.mx/biblioteca/leyes/archivosLeyes/117.pdf" target="_blank" rel="noopener noreferrer">Ley oficial ${I("external-link")}</a></div>${S.data.drivers.length ? cards : '<div class="empty"><p>Los conductores aparecerán al crear su cuenta y completar el perfil.</p></div>'}</section><section class="panel section-gap"><div class="row between wrap"><div><h2>Canjes para conductores</h2><p>Entrega beneficios físicos y registra el resultado. Una cancelación devuelve los puntos automáticamente.</p></div><span class="badge ${pendingRewards ? "pending" : "neutral"}">${(rewardOperations.pending || []).length} pendientes</span></div><div class="reward-operations">${pendingRewards || "<div class=\"empty\"><p>No hay recompensas pendientes de entrega.</p></div>"}</div></section><section class="panel section-gap"><h2>Control de edición de perfiles</h2><p>Los perfiles completos permanecen protegidos. Una autorización abre una ventana de 24 horas y queda registrada en auditoría.</p><div class="managed-profiles">${managedProfiles || '<div class="empty"><p>No hay perfiles para administrar.</p></div>'}</div></section>`,
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
  $$("[data-vehicle-photo]").forEach(
    (b) =>
      (b.onclick = () =>
        run(async () => {
          await loadVehiclePhoto(b.dataset.vehiclePhoto);
          openModal(
            "Frente y placa de la unidad",
            `<img class="operations-vehicle-photo" src="${e(S.vehiclePhotoUrls[b.dataset.vehiclePhoto] || "")}" alt="Fotografía frontal de la unidad"><p class="hint">Confirma que la unidad, el color y la placa coincidan con el expediente antes de autorizar.</p>`,
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
  $$("[data-billing]").forEach((item) => {
    item.onclick = () => {
      const d = S.data.drivers.find((driver) => driver.id === item.dataset.billing);
      const weekly = d.billing_mode !== "commission";
      openModal(
        "Modalidad de cobro de " + d.full_name,
        `<form id="driver-billing"><label>Esquema<select name="billing_mode"><option value="weekly_fee" ${weekly ? "selected" : ""}>Aportación semanal</option><option value="commission" ${weekly ? "" : "selected"}>Comisión por viaje</option></select></label><label>Aportación semanal (MXN)<input name="weekly_fee" type="number" min="0" max="1000" step="0.01" value="${Number(d.weekly_fee_cents || 50000) / 100}"></label><div class="grid2"><label>Comisión en efectivo (%)<input name="cash_commission" type="number" min="0" max="50" step="0.01" value="${Number(d.cash_commission_bps || 0) / 100}"></label><label>Comisión electrónica (%)<input name="card_commission" type="number" min="0" max="50" step="0.01" value="${Number(d.card_commission_bps || 1000) / 100}"></label></div><label>Motivo del cambio<textarea name="note" required minlength="5" maxlength="500" placeholder="Acuerdo comercial autorizado para este conductor."></textarea></label><div class="hint" id="billing-explanation"></div><button class="btn wide" type="submit">Guardar modalidad ${I("shield-check")}</button></form>`,
      );
      const form = $("#driver-billing");
      const explain = (changed = false) => {
        const commission = form.elements.billing_mode.value === "commission";
        if (!commission) {
          form.elements.cash_commission.value = "0";
          form.elements.cash_commission.disabled = true;
          form.elements.weekly_fee.disabled = false;
          if (changed || !form.elements.card_commission.value) form.elements.card_commission.value = "10";
          $("#billing-explanation").textContent = "El conductor conserva todo el efectivo. En pagos electrónicos recibe el porcentaje restante después de la comisión configurada.";
        } else {
          form.elements.cash_commission.disabled = false;
          form.elements.weekly_fee.disabled = true;
          if (changed || Number(form.elements.cash_commission.value) === 0) form.elements.cash_commission.value = "20";
          if (changed || Number(form.elements.card_commission.value) === 10) form.elements.card_commission.value = "20";
          $("#billing-explanation").textContent = "No se genera aportación semanal. La comisión electrónica se retiene al cobrar; la de efectivo se acumula para transferencia semanal.";
        }
      };
      form.elements.billing_mode.onchange = () => explain(true);
      explain();
      bindForm("#driver-billing", async (values) => {
        const mode = values.billing_mode;
        await rpc("set_driver_billing", {
          driver_id: d.id,
          billing_mode: mode,
          weekly_fee_cents: mode === "weekly_fee" ? cents(values.weekly_fee) : Number(d.weekly_fee_cents || 50000),
          cash_commission_bps: mode === "weekly_fee" ? 0 : cents(values.cash_commission),
          card_commission_bps: cents(values.card_commission),
          note: values.note,
        });
        closeModal();
        await refreshPage();
        notify("Modalidad comercial actualizada para nuevos viajes.");
      });
    };
  });
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
  $$("[data-reward-review]").forEach((item) => {
    item.onclick = () => {
      const fulfilled = item.dataset.result === "fulfilled";
      openModal(
        fulfilled ? "Confirmar entrega" : "Cancelar recompensa",
        `<form id="reward-review"><p>${fulfilled ? "Confirma que el conductor recibió el beneficio." : "Los puntos se devolverán al conductor y el canje quedará cancelado."}</p><label>Nota de Operaciones<textarea name="note" required minlength="5" maxlength="500" placeholder="Folio, proveedor o motivo de la decisión."></textarea></label><button class="btn wide" type="submit">${fulfilled ? "Registrar entrega" : "Cancelar y devolver puntos"}</button></form>`,
      );
      bindForm("#reward-review", async (values) => {
        await rpc("review_reward_redemption", {
          redemption_id: item.dataset.rewardReview,
          status: item.dataset.result,
          note: values.note,
        });
        closeModal();
        await refreshPage();
        notify(fulfilled ? "Entrega registrada." : "Canje cancelado y puntos devueltos.");
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
function auditKpis(summary = {}) {
  return `<div class="grid4 stats report-kpis"><div class="stat"><small>Viajes completados</small><strong>${summary.completed || 0}</strong><p>${summary.cancelled || 0} cancelados · ${summary.active || 0} en operación</p></div><div class="stat"><small>Ingresos registrados</small><strong>${money(summary.gross_cents)}</strong><p>Ticket promedio ${money(summary.average_ticket_cents)}</p></div><div class="stat"><small>Ganancia de plataforma</small><strong>${money(summary.platform_commission_cents)}</strong><p>Ingreso estimado por comisiones</p></div><div class="stat"><small>Calidad y seguridad</small><strong>${summary.average_rating ? `${decimal(summary.average_rating)}/5` : "Sin datos"}</strong><p>${summary.incidents || 0} incidentes · ${summary.open_incidents || 0} abiertos</p></div></div>`;
}
function overviewReport(report) {
  const periodCards = ["day", "week", "month", "year"].map((key) => {
    const item = report.periods?.[key] || {};
    return `<article><small>${e(periodNames[key])}</small><strong>${item.completed || 0} viajes</strong><span>${money(item.gross_cents)} registrados</span><span>${money(item.platform_commission_cents)} comisión</span></article>`;
  }).join("");
  const series = report.series || [];
  const max = Math.max(1, ...series.map((item) => Number(item.gross_cents || 0)));
  const chart = series.slice(-31).map((item) => `<div class="report-bar" title="${e(item.day)} · ${money(item.gross_cents)}"><span style="height:${Math.max(3, Math.round((Number(item.gross_cents || 0) / max) * 100))}%"></span><small>${e(String(item.day).slice(8))}</small></div>`).join("");
  return `<section class="period-comparison">${periodCards}</section><div class="grid2 report-grid"><section class="panel"><div class="row between wrap"><div><h2>Actividad e ingresos</h2><p>Últimos ${Math.min(31, series.length)} días del periodo elegido.</p></div><span class="badge neutral">${decimal(report.summary?.distance_km)} km recorridos</span></div><div class="report-chart">${chart || '<div class="empty"><p>Sin actividad en este periodo.</p></div>'}</div></section><section class="panel"><h2>Distribución económica</h2><div class="receipt-row"><span>Tarifas de viaje</span><strong>${money(report.summary?.fares_cents)}</strong></div><div class="receipt-row"><span>Propinas</span><strong>${money(report.summary?.tips_cents)}</strong></div><div class="receipt-row"><span>Descuentos y recompensas</span><strong>${money(report.summary?.discounts_cents)}</strong></div><div class="receipt-row"><span>Pago en efectivo</span><strong>${money(report.summary?.cash_cents)}</strong></div><div class="receipt-row"><span>Pago con tarjeta</span><strong>${money(report.summary?.card_cents)}</strong></div><div class="receipt-row total"><span>Ingreso de conductores</span><strong>${money(report.summary?.driver_earnings_cents)}</strong></div></section></div><section class="panel section-gap"><h2>Rendimiento de la flotilla</h2><div class="table-wrap"><table><thead><tr><th>Conductor</th><th>Viajes</th><th>Ingresos</th><th>Comisión</th><th>Rating</th><th>Incidentes</th></tr></thead><tbody>${(report.drivers || []).map((item) => `<tr><td><strong>${e(item.full_name)}</strong><small>${e(item.vehicle || "Unidad pendiente")} · ${e(item.plate || "Sin placas")}</small></td><td>${item.completed}</td><td>${money(item.gross_cents)}</td><td>${money(item.platform_commission_cents)}</td><td>${item.rating ? `${decimal(item.rating)}/5` : "Sin datos"}</td><td>${item.incidents}</td></tr>`).join("") || '<tr><td colspan="6">Sin conductores registrados.</td></tr>'}</tbody></table></div></section>`;
}
function driversReport(report) {
  return `<section class="panel"><h2>Resultados individuales</h2><p>Cada ficha separa ingresos cobrados, ingreso estimado del conductor, comisión, actividad, calificaciones e incidentes.</p><div class="driver-report-list">${(report.drivers || []).map((item, index) => `<details class="driver-report-card" ${index === 0 && S.auditFilters.driver_id ? "open" : ""}><summary><span><strong>${e(item.full_name)}</strong><small>${e(item.vehicle || "Unidad pendiente")} · ${e(item.plate || "Sin placas")}</small></span><span><strong>${item.completed} viajes</strong><small>${money(item.gross_cents)}</small></span>${I("chevron-down")}</summary><div class="driver-report-body"><div><small>Ingreso del conductor</small><strong>${money(item.driver_earnings_cents)}</strong></div><div><small>Comisión Yavoi!</small><strong>${money(item.platform_commission_cents)}</strong></div><div><small>Rating</small><strong>${item.rating ? `${decimal(item.rating)}/5 (${item.ratings_count})` : "Sin datos"}</strong></div><div><small>Incidentes</small><strong>${item.incidents}</strong></div><div><small>Viajes cancelados</small><strong>${item.cancelled}</strong></div><div><small>Último viaje</small><strong>${item.last_trip_at ? date(item.last_trip_at) : "Sin viajes"}</strong></div></div><a class="btn secondary" href="#audit" data-driver-report="${e(item.id)}">Generar informe individual ${I("file-text")}</a></details>`).join("") || '<div class="empty"><p>Sin conductores registrados.</p></div>'}</div></section>`;
}
function incidentsReport(report) {
  return `<section class="panel"><div class="row between wrap"><div><h2>Incidentes y seguimiento</h2><p>Motivo, persona que reportó, viaje relacionado y respuesta de Operaciones.</p></div><span class="badge ${report.summary?.open_incidents ? "pending" : "neutral"}">${report.summary?.open_incidents || 0} pendientes</span></div><div class="audit-list">${(report.incidents || []).map((item) => `<details class="audit-event"><summary><span class="audit-event-icon">${I("message-square-warning")}</span><span><strong>${e(item.subject)}</strong><small>${date(item.created_at)} · Reportó ${e(item.reported_by)}</small></span><span class="badge ${item.status === "resolved" ? "" : "pending"}">${e({ open: "Abierto", reviewing: "En revisión", resolved: "Resuelto" }[item.status] || item.status)}</span>${I("chevron-down")}</summary><div class="audit-event-detail"><p>${e(item.body)}</p><div class="audit-detail-grid"><span><small>Conductor</small><strong>${e(item.driver_name || "Sin conductor asignado")}</strong></span><span><small>Viaje</small><strong>${e(item.origin || "Sin viaje")} ${item.destination ? `→ ${e(item.destination)}` : ""}</strong></span></div>${item.response ? `<div class="hint"><strong>Respuesta de Operaciones</strong><br>${e(item.response)}</div>` : '<p class="hint warning">Aún no hay respuesta registrada.</p>'}<a class="link" href="${item.trip_id ? `#trip/${e(item.trip_id)}` : "#help"}">${item.trip_id ? "Abrir viaje relacionado" : "Abrir bandeja de reportes"}</a></div></details>`).join("") || '<div class="empty"><p>No hay incidentes en este periodo.</p></div>'}</div></section>`;
}
function ratingsReport(report) {
  const counts = [5, 4, 3, 2, 1].map((star) => ({ star, count: (report.ratings || []).filter((item) => Number(item.stars) === star).length }));
  const max = Math.max(1, ...counts.map((item) => item.count));
  return `<div class="grid2 report-grid"><section class="panel"><h2>Distribución de valoraciones</h2><div class="rating-distribution">${counts.map((item) => `<div><span>${item.star} ${I("star")}</span><progress max="${max}" value="${item.count}">${item.count}</progress><strong>${item.count}</strong></div>`).join("")}</div></section><section class="panel"><h2>Indicadores de calidad</h2><div class="receipt-row"><span>Promedio de conductores</span><strong>${report.summary?.average_rating ? `${decimal(report.summary.average_rating)}/5` : "Sin datos"}</strong></div><div class="receipt-row"><span>Evaluaciones recibidas</span><strong>${report.summary?.ratings_count || 0}</strong></div><div class="receipt-row"><span>Conductores evaluados</span><strong>${new Set((report.ratings || []).map((item) => item.driver_id)).size}</strong></div></section></div><section class="panel section-gap"><h2>Comentarios recientes</h2><div class="audit-list">${(report.ratings || []).map((item) => `<details class="audit-event"><summary><span class="audit-event-icon">${I("star")}</span><span><strong>${e(item.driver_name)}</strong><small>${date(item.created_at)} · Evaluó ${e(item.author_name)}</small></span><span class="badge">${item.stars}/5</span>${I("chevron-down")}</summary><div class="audit-event-detail"><div class="audit-detail-grid"><span><small>Comodidad</small><strong>${item.comfort || "—"}/5</strong></span><span><small>Seguridad</small><strong>${item.safety || "—"}/5</strong></span></div><p>${e(item.comment || "Sin comentario escrito.")}</p><a class="link" href="#trip/${e(item.trip_id)}">Abrir viaje relacionado</a></div></details>`).join("") || '<div class="empty"><p>No hay valoraciones en este periodo.</p></div>'}</div></section>`;
}
function insuranceReport(report) {
  return `<section class="panel"><div class="row between wrap"><div><h2>Control de pólizas de seguro</h2><p>Los avisos comienzan 60 días antes del vencimiento. Una póliza vencida impide que la unidad reciba viajes.</p></div><button class="btn" data-renew-policy="">Registrar o renovar póliza ${I("file-plus-2")}</button></div><div class="insurance-list">${(report.insurance || []).map((item) => { const [label, kind] = insuranceStatus(item.status); return `<article class="insurance-card"><div class="insurance-status ${e(kind || "valid")}">${I(item.status === "valid" ? "shield-check" : "shield-alert")}</div><div><strong>${e(item.full_name)}</strong><p>${e(item.vehicle || "Unidad pendiente")} · ${e(item.plate || "Sin placas")}</p><small>Vigencia: ${item.insurance_expires ? date(item.insurance_expires) : "Sin fecha"}${item.days_remaining != null ? ` · ${item.days_remaining} días restantes` : ""}</small></div><span class="badge ${e(kind)}">${e(label)}</span><div class="row wrap">${item.insurance_path ? `<button class="btn secondary" data-policy="${e(item.insurance_path)}">Ver póliza PDF ${I("file-text")}</button>` : ""}<button class="btn" data-renew-policy="${e(item.id)}">${item.insurance_path ? "Renovar" : "Registrar"}</button></div></article>`; }).join("") || '<div class="empty"><p>No hay unidades registradas.</p></div>'}</div></section>`;
}
function auditLogReport(report) {
  const actors = [...new Map((report.audit || []).map((item) => [item.actor_id, item.actor_name || item.actor_email || "Sin identificar"])).entries()];
  const groups = [...new Set((report.audit || []).map((item) => auditActionInfo(item.action)[1]))].sort();
  return `<section class="panel"><div class="row between wrap"><div><h2>Registro de cambios</h2><p>Consulta quién realizó cada acción, cuándo ocurrió y qué registro fue afectado.</p></div><div class="row wrap"><button class="btn secondary" data-audit-toggle="open">Abrir todos</button><button class="btn secondary" data-audit-toggle="close">Colapsar todos</button></div></div><form id="audit-log-filter" class="audit-log-filters"><label>Buscar<input name="search" placeholder="Acción, persona o detalle"></label><label>Área<select name="group"><option value="">Todas</option>${groups.map((group) => `<option>${e(group)}</option>`).join("")}</select></label><label>Responsable<select name="actor"><option value="">Todos</option>${actors.map(([id, name]) => `<option value="${e(id)}">${e(name)}</option>`).join("")}</select></label></form><div class="audit-list" id="audit-list">${(report.audit || []).map((item) => { const [label, group] = auditActionInfo(item.action); const target = item.target_name || (item.target_trip_origin ? `${item.target_trip_origin} → ${item.target_trip_destination}` : item.target_id ? `Registro ${String(item.target_id).slice(0, 8)}` : "Plataforma Yavoi!"); const details = auditDetailItems(item.detail); const search = `${label} ${group} ${item.actor_name} ${target} ${details.map((detail) => detail.value).join(" ")}`.toLowerCase(); return `<details class="audit-event" data-audit-group="${e(group)}" data-audit-actor="${e(item.actor_id)}" data-audit-search="${e(search)}"><summary><span class="audit-event-icon">${I(group === "Pagos" ? "credit-card" : group === "Conductores" ? "car-front" : group === "Incidentes" ? "shield-alert" : group === "Informes" ? "file-chart-column" : "history")}</span><span><strong>${e(label)}</strong><small>${date(item.created_at)} · ${e(item.actor_name || item.actor_email || "Responsable sin identificar")}</small></span><span class="badge neutral">${e(group)}</span>${I("chevron-down")}</summary><div class="audit-event-detail"><div class="audit-who"><div><small>REALIZADO POR</small><strong>${e(item.actor_name || "Sin nombre")}</strong><span>${e(item.actor_email || roles[item.actor_role] || "Operaciones")}</span></div><div><small>REGISTRO AFECTADO</small><strong>${e(target)}</strong><span>${e(item.target_role ? roles[item.target_role] : "")}</span></div></div>${details.length ? `<div class="audit-detail-grid">${details.map((detail) => `<span><small>${e(detail.label)}</small><strong>${e(detail.value)}</strong></span>`).join("")}</div>` : '<p class="hint">No se guardaron datos adicionales para esta acción.</p>'}<small>Folio de auditoría ${item.id}</small></div></details>`; }).join("") || '<div class="empty"><p>No hay cambios administrativos en este periodo.</p></div>'}</div><p class="hint hidden" id="audit-empty">Ningún cambio coincide con los filtros.</p></section>`;
}
function renderAuditReport() {
  const report = S.auditReport;
  const filters = S.auditFilters;
  const custom = filters.period === "custom";
  const reportContent = ({ overview: overviewReport, drivers: driversReport, incidents: incidentsReport, ratings: ratingsReport, insurance: insuranceReport, audit: auditLogReport })[filters.report](report);
  shell(
    `<form id="operations-report-filter" class="panel report-toolbar"><label>Informe<select name="report">${Object.entries(reportNames).map(([id, label]) => `<option value="${id}" ${filters.report === id ? "selected" : ""}>${e(label)}</option>`).join("")}</select></label><label>Periodo<select name="period">${Object.entries(periodNames).map(([id, label]) => `<option value="${id}" ${filters.period === id ? "selected" : ""}>${e(label)}</option>`).join("")}</select></label><label>Conductor<select name="driver_id"><option value="">Toda la flotilla</option>${(S.data.drivers || []).map((item) => `<option value="${e(item.id)}" ${filters.driver_id === item.id ? "selected" : ""}>${e(item.full_name)}</option>`).join("")}</select></label><label class="${custom ? "" : "hidden"}">Desde<input name="from" type="date" value="${e(filters.from)}"></label><label class="${custom ? "" : "hidden"}">Hasta<input name="to" type="date" value="${e(filters.to)}"></label><button class="btn" type="submit">Actualizar informe ${I("refresh-cw")}</button><div class="report-export-actions"><button class="btn navy" type="button" id="download-report">Descargar PDF ${I("file-down")}</button><button class="btn secondary" type="button" id="print-report">Imprimir ${I("printer")}</button></div></form><div class="report-period-label">${I("calendar-range")} ${e(reportPeriodLabel(report.meta))}${filters.driver_id ? ` · ${e(S.data.drivers.find((item) => item.id === filters.driver_id)?.full_name || "Conductor")}` : " · Toda la flotilla"}</div>${auditKpis(report.summary)}<div class="section-gap">${reportContent}</div>`,
    "Informes y auditoría",
    "Resultados claros de viajes, ingresos, conductores, seguridad, valoraciones, documentos y cambios administrativos.",
  );
  bindOperationsReportActions();
}
async function loadOperationsReport() {
  const payload = { ...S.auditFilters };
  if (payload.period !== "custom") { delete payload.from; delete payload.to; }
  S.auditReport = await rpc("operations_report", payload);
}
function audit() {
  if (S.auditReport) return renderAuditReport();
  shell('<section class="panel report-loading"><span></span><h2>Preparando tus indicadores</h2><p>Calculamos viajes, ingresos, valoraciones, incidentes y vigencias.</p></section>', "Informes y auditoría", "Información operativa protegida para la toma de decisiones.");
  run(async () => { await loadOperationsReport(); renderAuditReport(); });
}
function bindOperationsReportActions() {
  const filter = $("#operations-report-filter");
  filter.querySelector('[name="period"]').onchange = (event) => {
    const custom = event.target.value === "custom";
    filter.querySelectorAll('[name="from"],[name="to"]').forEach((input) => input.closest("label").classList.toggle("hidden", !custom));
  };
  bindForm("#operations-report-filter", async (values) => {
    if (values.period === "custom" && (!values.from || !values.to)) throw Error("Elige las dos fechas del periodo personalizado.");
    S.auditFilters = { report: values.report, period: values.period, driver_id: values.driver_id || "", from: values.from || "", to: values.to || "" };
    await loadOperationsReport();
    renderAuditReport();
  });
  $$('[data-driver-report]').forEach((item) => item.onclick = async (event) => {
    event.preventDefault();
    S.auditFilters = { ...S.auditFilters, report: "drivers", driver_id: item.dataset.driverReport };
    await run(async () => { await loadOperationsReport(); renderAuditReport(); });
  });
  $("#download-report").onclick = () => run(async () => {
    const logo = await imageUrlToDataUrl("/assets/yavoi-logo.png");
    await rpc("log_report_export", { report: S.auditFilters.report, format: "pdf", period: S.auditFilters.period, driver_id: S.auditFilters.driver_id || null });
    const pdf = await buildOperationsPdf(S.auditReport, { type: S.auditFilters.report, logoDataUrl: logo });
    const driverName = S.auditFilters.driver_id ? S.data.drivers.find((item) => item.id === S.auditFilters.driver_id)?.full_name : "flotilla";
    pdf.save(`Yavoi-${S.auditFilters.report}-${String(driverName || "flotilla").replace(/[^a-z0-9]+/gi, "-")}.pdf`);
    notify("Informe PDF generado correctamente.");
  });
  $("#print-report").onclick = () => {
    const printWindow = window.open("", "_blank");
    if (!printWindow) return notify("Permite ventanas emergentes para imprimir el informe.");
    printWindow.opener = null;
    run(async () => {
      await rpc("log_report_export", { report: S.auditFilters.report, format: "print", period: S.auditFilters.period, driver_id: S.auditFilters.driver_id || null });
      printWindow.document.write(reportPrintHtml(S.auditReport, S.auditFilters.report));
      printWindow.document.close();
    });
  };
  $$('[data-policy]').forEach((item) => item.onclick = () => run(async () => {
    const { data, error } = await db.storage.from("yavoi-documents").createSignedUrl(item.dataset.policy, 90);
    if (error) throw error;
    window.open(data.signedUrl, "_blank", "noopener,noreferrer");
  }));
  $$('[data-renew-policy]').forEach((item) => item.onclick = () => {
    const current = (S.auditReport.insurance || []).find((policy) => policy.id === item.dataset.renewPolicy);
    openModal("Registrar póliza de seguro", `<form id="renew-policy"><label>Conductor<select name="driver_id" required><option value="">Selecciona una unidad</option>${(S.auditReport.insurance || []).map((policy) => `<option value="${e(policy.id)}" ${current?.id === policy.id ? "selected" : ""}>${e(policy.full_name)} · ${e(policy.plate || "Sin placas")}</option>`).join("")}</select></label><label>Nueva fecha de caducidad<input name="insurance_expires" type="date" min="${new Date().toISOString().slice(0, 10)}" required value="${e(current?.insurance_expires || "")}"></label><label>Póliza en PDF<input name="insurance_file" type="file" accept="application/pdf" required></label><label>Referencia de validación<textarea name="note" required minlength="5" maxlength="500" placeholder="Aseguradora, número de póliza o validación realizada."></textarea></label><p class="hint">El archivo se guarda en el depósito privado de documentos y sólo puede consultarlo su propietario y Operaciones.</p><button class="btn wide" type="submit">Guardar póliza y vigencia ${I("shield-check")}</button></form>`);
    bindForm("#renew-policy", async (values) => {
      const path = await upload(values.insurance_file, "yavoi-documents");
      await rpc("update_driver_insurance", { driver_id: values.driver_id, insurance_path: path, insurance_expires: values.insurance_expires, note: values.note });
      closeModal();
      await loadOperationsReport();
      renderAuditReport();
      notify("Póliza y fecha de caducidad actualizadas.");
    });
  });
  const auditFilter = $("#audit-log-filter");
  if (auditFilter) {
    const apply = () => {
      const values = Object.fromEntries(new FormData(auditFilter));
      let visible = 0;
      $$("#audit-list .audit-event").forEach((item) => {
        const show = (!values.group || item.dataset.auditGroup === values.group) && (!values.actor || item.dataset.auditActor === values.actor) && (!values.search || item.dataset.auditSearch.includes(values.search.toLowerCase()));
        item.classList.toggle("hidden", !show);
        if (show) visible += 1;
      });
      $("#audit-empty").classList.toggle("hidden", visible > 0);
    };
    auditFilter.oninput = apply;
    auditFilter.onchange = apply;
    $$('[data-audit-toggle]').forEach((item) => item.onclick = () => $$("#audit-list .audit-event:not(.hidden)").forEach((entry) => entry.open = item.dataset.auditToggle === "open"));
  }
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
  if (action === "refresh") return run(S.view === "opsmap" ? refreshOperationsMap : refreshPage);
  if (action === "open-chat") {
    $("#trip-chat")?.scrollIntoView({ behavior: "smooth", block: "center" });
    setTimeout(() => $("#chat-form input")?.focus(), 450);
    return;
  }
  if (action === "map-fullscreen") {
    const panel = b.closest(".map-panel");
    panel?.classList.toggle("fullscreen");
    b.querySelector("span").textContent = panel?.classList.contains("fullscreen") ? "Cerrar" : "Ampliar";
    setTimeout(() => S.map?.invalidateSize(), 80);
    return;
  }
  if (action === "cancel-map-placement") {
    setMapPicker();
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
  if (action === "settle-cancel-fee" || action === "waive-cancel-fee") {
    const waived = action === "waive-cancel-fee";
    openModal(
      waived ? "Condonar cuota de cancelación" : "Confirmar cuota recibida",
      `<form id="settle-cancellation"><p>${waived ? "La cuota dejará de estar pendiente y la decisión quedará registrada para seguimiento." : "Confirma únicamente cuando el importe haya sido recibido. Esta acción actualizará los ingresos y la conciliación."}</p><label>Nota de seguimiento<textarea name="note" required minlength="5" maxlength="500" placeholder="Forma de pago o motivo de la decisión"></textarea></label><button class="btn ${waived ? "secondary" : ""} wide" type="submit">${waived ? "Confirmar condonación" : "Registrar pago"}</button></form>`,
    );
    bindForm("#settle-cancellation", async (values) => {
      await rpc("settle_cancellation_fee", {
        trip_id: t.id,
        status: waived ? "waived" : "paid",
        note: values.note,
      });
      closeModal();
      await tripView(t.id);
      notify(waived ? "Cuota condonada y registrada." : "Cuota conciliada correctamente.");
    });
    return;
  }
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
    const freeRewardTrip = Number(t.total_cents || 0) === 0;
    const cashConfirmation = freeRewardTrip
      ? '<label class="check"><input type="checkbox" required>Confirmo que el viaje cubierto por la recompensa llegó al destino.</label>'
      : '<label class="check"><input name="cash_received" type="checkbox" required>Recibí el pago y entregué el cambio correspondiente.</label>';
    openModal(
      freeRewardTrip ? "Llegada con recompensa" : t.payment_method === "card" ? "Llegada confirmada" : "Llegada y pago en efectivo",
      `<p>Confirma con el pasajero que llegaron al destino antes de cerrar el viaje.</p><div class="receipt-row"><span>Total</span><strong>${money(t.total_cents || 0)}</strong></div>${t.reward_discount_cents ? `<div class="receipt-row positive-points"><span>Recompensa aplicada</span><strong>-${money(t.reward_discount_cents)}</strong></div>` : ""}${t.payment_method === "cash" && !freeRewardTrip ? `<div class="receipt-row"><span>Paga con</span><strong>${money(t.cash_tender_cents)}</strong></div><div class="receipt-row total"><span>Entrega de cambio</span><strong>${money(changeDue(t.total_cents ?? t.fare_cents, t.cash_tender_cents))}</strong></div>` : t.payment_method === "card" ? `<div class="hint">Pago con tarjeta confirmado por Mercado Pago.</div>` : '<div class="hint">La tarifa está cubierta por Puntos Viajeros.</div>'}<form id="finish">${t.payment_method === "cash" ? cashConfirmation : '<label class="check"><input type="checkbox" required>Confirmo que el pasajero llegó al destino.</label>'}<button class="btn wide" type="submit">Completar viaje ${I("check")}</button></form>`,
    );
    bindForm("#finish", async () => {
      await rpc("transition", { trip_id: t.id, status: "completed", cash_received: t.payment_method === "cash" });
      closeModal();
      await tripView(t.id);
    });
    return;
  }
  if (action === "cancel") {
    return run(async () => {
      const terms = await rpc("cancellation_quote", { trip_id: t.id });
      const cancellationReasons = S.profile.role === "driver"
        ? [["vehicle_issue", "Falla o imprevisto con mi unidad"], ["passenger_absent", "No localizo al pasajero"], ["safety", "Situación de seguridad"], ["other", "Otro motivo"]]
        : S.profile.role === "admin"
          ? [["operations", "Decisión de Operaciones"], ["safety", "Situación de seguridad"], ["vehicle_issue", "Unidad fuera de servicio"], ["other", "Otro motivo"]]
          : [["changed_plans", "Cambió mi plan"], ["wrong_location", "Ingresé una ubicación incorrecta"], ["driver_delay", "Demora de la unidad"], ["safety", "Seguridad o identidad no coincide"], ["other", "Otro motivo"]];
      const reasonOptions = cancellationReasons.map(([value, label]) => `<option value="${value}">${label}</option>`).join("");
      const feeNotice = Number(terms.fee_cents || 0) > 0
        ? `<div class="cancellation-charge">${I("circle-dollar-sign")}<div><small>CUOTA APLICABLE</small><strong>${money(terms.fee_cents)}</strong><p>${e(terms.explanation)}</p></div></div>`
        : `<div class="hint">${I("shield-check")} ${e(terms.explanation)}</div>`;
      openModal(
        "Revisa antes de cancelar",
        `<form id="cancel">${feeNotice}${terms.payment_method === "card" && Number(terms.refund_cents || 0) > 0 ? `<div class="receipt-row"><span>Reembolso estimado a tu tarjeta</span><strong>${money(terms.refund_cents)}</strong></div>` : ""}<label>Motivo de cancelación<select name="reason_code" required><option value="">Selecciona un motivo</option>${reasonOptions}</select></label><label>Describe el motivo<textarea name="reason" required minlength="5" maxlength="500"></textarea></label><label class="check"><input type="checkbox" required>Entiendo el importe, el reembolso y que ambas partes recibirán el aviso.</label><button class="btn danger wide" type="submit">Confirmar cancelación</button></form>`,
      );
      bindForm("#cancel", async (v) => {
        const cancelled = await rpc("transition", { trip_id: t.id, status: "cancelled", reason_code: v.reason_code, reason: v.reason });
        let refundPending = false;
        if (cancelled.refund_payment_id) {
          const { data, error } = await db.functions.invoke("mercado-pago-payment", { body: { action: "refund", payment_id: cancelled.refund_payment_id } });
          refundPending = !!(error || data?.error);
        }
        closeModal();
        await tripView(t.id);
        if (refundPending) notify("El viaje se canceló. Operaciones dará seguimiento al reembolso pendiente.");
        else if (cancelled.cancellation_refund_cents) notify(`Cancelación confirmada. Reembolso: ${money(cancelled.cancellation_refund_cents)}.`);
        else if (cancelled.cancellation_fee_cents) notify(`Cancelación confirmada. Cuota registrada: ${money(cancelled.cancellation_fee_cents)}.`);
        else notify("Cancelación confirmada sin cargo.");
      });
    });
  }
  if (action === "rate") {
    const rider = S.profile.role === "passenger";
    openModal(
      rider ? "¿Cómo estuvo tu viaje?" : "¿Cómo fue viajar con tu pasajero?",
      `<form id="rating"><p>Tu evaluación se guarda una sola vez por viaje.</p><div class="stars">${[1, 2, 3, 4, 5].map((n) => `<label><input name="stars" type="radio" value="${n}" ${n === 5 ? "checked" : ""} required>${n}${I("star")}</label>`).join("")}</div>${rider ? `<div class="modal-grid"><label>Comodidad<select name="comfort">${[5, 4, 3, 2, 1].map((n) => `<option>${n}</option>`).join("")}</select></label><label>Percepción de seguridad<select name="safety">${[5, 4, 3, 2, 1].map((n) => `<option>${n}</option>`).join("")}</select></label></div>` : ""}<label class="section-gap">Comentario (opcional)<textarea name="comment" maxlength="1000"></textarea></label>${rider ? `<section class="rating-report"><label class="check"><input name="report_issue" type="checkbox">También quiero reportar un problema de este servicio</label><div id="rating-report-fields" class="hidden"><label>Motivo del reporte<select name="report_subject"><option>Seguridad durante el viaje</option><option>Problema con el viaje</option><option>Tarifa o efectivo</option><option>Trato o conducta</option><option>Objeto olvidado</option><option>Otro</option></select></label><label>Descripción para Operaciones<textarea name="report_body" minlength="10" maxlength="2000"></textarea></label></div></section>` : ""}<button class="btn wide" type="submit">Enviar evaluación</button></form>`,
    );
    const reportToggle = $('[name="report_issue"]');
    if (reportToggle) reportToggle.onchange = () => {
      const fields = $("#rating-report-fields");
      const body = $('[name="report_body"]');
      fields.classList.toggle("hidden", !reportToggle.checked);
      body.required = reportToggle.checked;
    };
    bindForm("#rating", async (v) => {
      await rpc("rating_and_report", {
        trip_id: t.id,
        stars: Number(v.stars),
        comfort: v.comfort ? Number(v.comfort) : null,
        safety: v.safety ? Number(v.safety) : null,
        comment: v.comment,
        report_issue: v.report_issue === "on",
        report_subject: v.report_subject,
        report_body: v.report_body,
      });
      closeModal();
      await tripView(t.id);
      notify(v.report_issue === "on" ? "Evaluación y reporte enviados a Operaciones." : "Gracias. Tu evaluación quedó registrada.");
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
      `<p>Yavoi! · ${e(t.id.slice(0, 8).toUpperCase())}</p><div class="route-line">${e(t.origin)} → ${e(t.destination)}</div><div class="receipt-row"><span>Finalizó</span><span>${date(t.completed_at)}</span></div><div class="receipt-row"><span>Método</span><strong>${Number(t.total_cents) === 0 ? "Puntos Viajeros" : t.payment_method === "card" ? "Tarjeta · Mercado Pago" : "Efectivo recibido"}</strong></div><div class="receipt-row"><span>Viaje</span><strong>${money(t.fare_cents)}</strong></div>${t.reward_discount_cents ? `<div class="receipt-row positive-points"><span>Recompensa aplicada</span><strong>-${money(t.reward_discount_cents)}</strong></div>` : ""}${t.tip_cents ? `<div class="receipt-row"><span>Propina</span><strong>${money(t.tip_cents)}</strong></div>` : ""}<div class="receipt-row total"><span>Total</span><strong>${money(t.total_cents ?? t.fare_cents)}</strong></div><p class="hint">Este comprobante de servicio no es una factura fiscal.</p>`,
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
  else if (S.view === "rewards") {
    S.data = await rpc("dashboard");
    rewards();
  } else ({ trips: tripsView, profile, wallet, payments: paymentsView, help, fleet, rates, marketing: marketingView, audit })[S.view]?.();
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
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "reward_entries", filter: `user_id=eq.${S.user.id}` }, () => safeRefresh())
    .on("postgres_changes", { event: "*", schema: "public", table: "reward_redemptions", filter: `user_id=eq.${S.user.id}` }, () => safeRefresh())
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "trip_events" }, (payload) => {
      if (payload.new?.actor_id === S.user.id) return safeRefresh();
      const event = payload.new?.event;
      if (["cancelled", "cancellation_fee_paid", "cancellation_fee_waived"].includes(event)) {
        const body = event === "cancelled"
          ? `La otra parte canceló el servicio. Abre el viaje para revisar motivo, cuota y reembolso.`
          : event === "cancellation_fee_paid"
            ? "La cuota de cancelación quedó conciliada."
            : "Operaciones condonó la cuota de cancelación.";
        serviceNotification("Actualización de cancelación", body, {
          tag: `yavoi-cancellation-${payload.new.trip_id}`,
          target: `trip/${payload.new.trip_id}`,
        });
      }
      safeRefresh();
    })
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "messages" }, (payload) => {
      if (
        payload.new?.sender_id !== S.user.id &&
        payload.new?.trip_id === S.trip?.trip?.id &&
        document.hidden
      ) serviceNotification("Nuevo mensaje del viaje", "Abre Yavoi! para leer y responder la indicación.", {
        tag: `yavoi-message-${payload.new.trip_id}`,
        target: `trip/${payload.new.trip_id}`,
      });
      safeRefresh();
    })
    .subscribe();
  pollTimer = setInterval(safeRefresh, 15000);
}
async function safeRefresh() {
  if (S.refreshing || S.busy || modal.open || !S.profile || document.hidden) return;
  S.refreshing = true;
  try {
    if (S.view === "trip") await refreshTrip();
    else if (S.view === "home" && S.profile.role === "passenger") await refreshAvailableUnits({ fit: false });
    else if (S.view === "opsmap" && S.profile.role === "admin") await refreshOperationsMap();
    else if (S.view === "rewards") await refreshPage();
    else if (
      (S.view === "home" && S.profile.role === "driver") ||
      (S.profile.role === "admin" && ["home", "trips", "payments"].includes(S.view))
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
