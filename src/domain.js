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
    ["help", "shield-check", "Ayuda y seguridad"],
    ["profile", "user-round", "Mi perfil"],
  ],
  driver: [
    ["home", "navigation", "Conducir"],
    ["trips", "route", "Mis viajes"],
    ["wallet", "wallet", "Mis ingresos"],
    ["weekly", "calendar-check", "Cuota semanal"],
    ["rewards", "gift", "Recompensas"],
    ["help", "shield-check", "Ayuda y seguridad"],
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
    ["audit", "scroll-text", "Auditoría"],
    ["profile", "user-round", "Mi perfil"],
  ],
};
export const places = [
  { name: "Plaza de la República", lat: 28.19065, lng: -105.47045 },
  { name: "Tecnológico de Delicias", lat: 28.18415, lng: -105.4593 },
  { name: "Terminal de Autobuses", lat: 28.19265, lng: -105.4671 },
  { name: "Hospital Regional", lat: 28.18145, lng: -105.475 },
  { name: "Parque Fundadores", lat: 28.19175, lng: -105.4812 },
  { name: "Centro de Meoqui", lat: 28.27215, lng: -105.48075 },
];
export const active = (t) => !["completed", "cancelled"].includes(t.status);
export const cents = (value) => {
  const number = Number(value);
  if (!Number.isFinite(number) || number < 0) throw Error("Importe inválido.");
  return Math.round(number * 100);
};
export const changeDue = (fare, tender) => Math.max(0, (tender ?? fare) - fare);
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
  if (/rate limit/i.test(m)) return "Demasiados intentos. Espera unos minutos.";
  if (/Failed to fetch|NetworkError|fetch failed/i.test(m))
    return "No hay conexión. Tus cambios no se guardaron. Inténtalo de nuevo.";
  if (/duplicate key|unique constraint/i.test(m))
    return "Este registro ya existe o el viaje ya fue asignado. Actualiza la pantalla.";
  if (/check constraint|invalid input syntax|not-null/i.test(m))
    return "Revisa los datos del formulario.";
  return m || "No se pudo completar la acción.";
}
