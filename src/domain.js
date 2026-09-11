export const roles = { passenger: "Pasajero", driver: "Conductor", admin: "Operaciones" };
export const statuses = {
  payment_pending: "Confirmando pago",
  scheduled: "Programado",
  requested: "Buscando conductor",
  accepted: "Conductor en camino",
  arrived: "Tu conductor llegó",
  in_progress: "Viaje en curso",
  completed: "Completado",
  cancelled: "Cancelado",
};
export const navs = {
  passenger: [
    ["home", "map-pin", "Pedir un viaje"],
    ["trips", "route", "Mis viajes"],
    ["wallet", "wallet", "Mi cartera"],
    ["rewards", "gift", "Recompensas"],
    ["profile", "user-round", "Mi perfil"],
  ],
  driver: [
    ["home", "navigation", "Conducir"],
    ["trips", "route", "Mis viajes"],
    ["wallet", "wallet", "Mis ingresos"],
    ["rewards", "gift", "Recompensas"],
    ["profile", "user-round", "Mi perfil"],
  ],
  admin: [
    ["home", "layout-dashboard", "Resumen"],
    ["opsmap", "map", "Mapa en vivo"],
    ["trips", "route", "Viajes"],
    ["fleet", "car", "Conductores y flotilla"],
    ["payments", "credit-card", "Pagos y cuotas"],
    ["help", "headset", "Reportes"],
    ["rates", "sliders-horizontal", "Tarifas"],
    ["marketing", "megaphone", "Recompensas y publicidad"],
    ["audit", "scroll-text", "Auditoría"],
    ["profile", "user-round", "Mi perfil"],
  ],
};
export const DEFAULT_ORIGIN = { name: "Centro de Delicias", lat: 28.19065, lng: -105.47045 };
export const places = [
  { name: "Omnibus Delicias", lat: 28.196877124464113, lng: -105.46705280588705 },
  { name: "Rápidos Delicias", lat: 28.197719970347674, lng: -105.46801468291481 },
  { name: "Autobuses Chihuahuenses", lat: 28.199181012388152, lng: -105.46962876145041 },
  { name: "Hotel Baeza", lat: 28.196559401371477, lng: -105.470620961273 },
  { name: "Hotel Oasis Suite", lat: 28.196397470547517, lng: -105.47075683778465 },
  { name: "Hotel El Dorado Inn", lat: 28.197964529832333, lng: -105.46845486147728 },
  { name: "Hotel Casa Grande", lat: 28.192822971686198, lng: -105.46264658388489 },
  { name: "Hotel Los Cedros Inn", lat: 28.199502716407586, lng: -105.45266051756059 },
  { name: "American Inn Hotel y Suites", lat: 28.190635058197287, lng: -105.45602231310774 },
  { name: "Hotel Comfort Inn", lat: 28.193012729037207, lng: -105.45681979310845 },
];
export const active = (t) => !["completed", "cancelled"].includes(t.status);
export const cents = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw Error("Importe inválido.");
  return Math.round(number * 100);
};
export const changeDue = (fare, tender) => Math.max(0, (tender ?? fare) - fare);
export const serviceAssets = Object.freeze({
  basic: "/assets/services/basic.webp",
  large: "/assets/services/large.webp",
  commercial: "/assets/services/commercial.webp",
  plus: "/assets/services/plus.webp",
  pickup: "/assets/services/pickup.webp",
});
export const serviceAsset = (category) => serviceAssets[category] || serviceAssets.basic;
export const rewardEligibleForTrip = (reward = {}, quote = {}) =>
  ["fare_discount_fixed", "fare_discount_percent", "free_local_trip", "ride_amenity"].includes(
    reward.kind,
  ) &&
  (!reward.eligible_category || reward.eligible_category === quote.category) &&
  !(reward.kind === "free_local_trip" && quote.service_zone === "regional");
export const rewardDiscountCents = (reward = {}, quote = {}) => {
  if (!rewardEligibleForTrip(reward, quote)) return 0;
  const fare = Math.max(0, Number(quote.fare_cents) || 0);
  if (reward.kind === "fare_discount_fixed")
    return Math.min(fare, Math.max(0, Number(reward.value_cents) || 0));
  if (reward.kind === "fare_discount_percent")
    return Math.min(
      Math.round((fare * Math.max(0, Number(reward.value_percent) || 0)) / 100),
      Math.max(0, Number(reward.max_discount_cents) || 0),
    );
  if (reward.kind === "free_local_trip") return fare;
  return 0;
};
export const PASSENGER_POLICY_VERSION = "2026-09-11-cancelaciones";
export const PRIVACY_POLICY_VERSION = "2026-09-11";
export const TERMS_VERSION = "2026-09-11";
export const profileEditState = (profile = {}, now = Date.now()) => {
  const locked = Boolean(profile.profile_locked_at);
  const authorizedUntil = Date.parse(profile.profile_edit_allowed_until || "");
  const authorized = Number.isFinite(authorizedUntil) && authorizedUntil > now;
  return {
    locked,
    authorized,
    editable: profile.role === "admin" || !locked || authorized,
  };
};
export const passengerProfileStatus = (profile = {}) => {
  const isComplete = (value) =>
    typeof value === "boolean" ? value : String(value ?? "").trim().length > 0;
  const requirements = [
    ["Nombre completo", String(profile.full_name || "").trim().length >= 2],
    ["Teléfono", String(profile.phone || "").trim().length >= 10],
    ["Fotografía", profile.avatar_path],
    ["Contacto de emergencia", String(profile.emergency_name || "").trim().length >= 2],
    ["Teléfono de emergencia", String(profile.emergency_phone || "").trim().length >= 10],
    [
      "Políticas de seguridad aceptadas",
      profile.passenger_policy_accepted_at &&
        profile.passenger_policy_version === PASSENGER_POLICY_VERSION,
    ],
    [
      "Política de privacidad aceptada",
      profile.privacy_policy_accepted_at &&
        profile.privacy_policy_version === PRIVACY_POLICY_VERSION,
    ],
    [
      "Términos de servicio aceptados",
      profile.terms_accepted_at && profile.terms_version === TERMS_VERSION,
    ],
  ];
  const completed = requirements.filter(([, value]) => isComplete(value)).length;
  return {
    completed,
    total: requirements.length,
    percent: Math.round((completed / requirements.length) * 100),
    missing: requirements.filter(([, value]) => !isComplete(value)).map(([label]) => label),
  };
};
export const driverDossierStatus = (profile = {}, driver = {}) => {
  const today = new Date().toISOString().slice(0, 10);
  const isComplete = (value) =>
    typeof value === "boolean" ? value : String(value ?? "").trim().length > 0;
  const requirements = [
    ["Nombre completo", profile.full_name],
    ["Teléfono", profile.phone],
    ["Fotografía", profile.avatar_path || driver.avatar_path],
    ["Marca", driver.vehicle_make],
    ["Modelo", driver.vehicle_model],
    ["Año", driver.vehicle_year],
    ["Color", driver.vehicle_color],
    ["Placas", driver.plate],
    ["Número de licencia", driver.license_number],
    ["Vigencia de licencia", driver.license_expires && driver.license_expires >= today],
    ["Vigencia de seguro", driver.insurance_expires && driver.insurance_expires >= today],
    ["Licencia", driver.license_path],
    ["Póliza de seguro", driver.insurance_path],
    ["Carta de no antecedentes penales", driver.criminal_record_path],
    ["Carta de políticas Yavoi! firmada", driver.policy_commitment_path],
    ["Carta de obligaciones viales firmada", driver.traffic_law_commitment_path],
  ];
  const completed = requirements.filter(([, value]) => isComplete(value)).length;
  return {
    completed,
    total: requirements.length,
    percent: Math.round((completed / requirements.length) * 100),
    missing: requirements.filter(([, value]) => !isComplete(value)).map(([label]) => label),
  };
};
export const allowedView = (role, view) => navs[role]?.some(([v]) => v === view) || view === "trip";
export const mfaQrSource = (value) => {
  const qr = String(value || "").trim();
  if (/^data:image\/svg\+xml(?:;[^,]*)?,/i.test(qr)) return qr;
  if (/^<svg[\s>]/i.test(qr)) return "data:image/svg+xml;charset=utf-8," + encodeURIComponent(qr);
  throw Error("No pudimos generar el código QR. Usa la clave manual o vuelve a intentarlo.");
};
export const escapeHtml = (s) =>
  String(s ?? "").replace(
    /[&<>"']/g,
    (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c],
  );
export const money = (c) =>
  new Intl.NumberFormat("es-MX", { style: "currency", currency: "MXN" }).format((c || 0) / 100);
export function errorMessage(error) {
  const m = String(error?.message || error || "");
  if (/Invalid login credentials/i.test(m)) return "Correo o contraseña incorrectos.";
  if (/Email not confirmed/i.test(m)) return "Verifica tu correo antes de ingresar.";
  if (/provider.*not enabled|unsupported provider/i.test(m))
    return "Este acceso ya está preparado, pero falta activar las credenciales del proveedor en Yavoi!. Puedes continuar con correo y contraseña.";
  if (/rate limit/i.test(m)) return "Demasiados intentos. Espera unos minutos.";
  if (/Failed to fetch|NetworkError|fetch failed/i.test(m))
    return "No hay conexión. Tus cambios no se guardaron. Inténtalo de nuevo.";
  if (/duplicate key|unique constraint/i.test(m))
    return "Este registro ya existe o el viaje ya fue asignado. Actualiza la pantalla.";
  if (/check constraint|invalid input syntax|not-null/i.test(m))
    return "Revisa los datos del formulario.";
  return m || "No se pudo completar la acción.";
}
