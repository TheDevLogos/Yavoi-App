import "./operations-finance.css";
import { db, rpc, money, escapeHtml } from "./client.js";

const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
let role = "";
let channel = null;
let renderTimer = null;
let rendering = false;

function toast(message) {
  const target = $("#toast");
  if (!target) return;
  target.textContent = message;
  target.classList.add("show");
  clearTimeout(target._promotionTimer);
  target._promotionTimer = setTimeout(() => target.classList.remove("show"), 6500);
}

function notifyOperations(title, body, tag) {
  toast(`${title}. ${body}`);
  if (!("Notification" in window) || Notification.permission !== "granted") return;
  try {
    const notice = new Notification(title, {
      body,
      icon: "/icons/yavoi-192.png",
      badge: "/icons/yavoi-maskable-512.png",
      tag,
      renotify: true,
    });
    notice.onclick = () => {
      window.focus();
      location.hash = "marketing";
    };
  } catch {}
}

function statusName(status) {
  return ({ pending: "Semana abierta", overdue: "Pendiente de conciliación", paid: "Conciliado" })[status] || status;
}

function periodPayload() {
  const form = $("#operations-report-filter");
  if (!form) return { period: "month" };
  const values = Object.fromEntries(new FormData(form));
  const payload = {
    period: values.period || "month",
    driver_id: values.driver_id || "",
  };
  if (payload.period === "custom") {
    payload.from = values.from || "";
    payload.to = values.to || "";
  }
  return payload;
}

async function enhancePayments() {
  // Digital payment, reimbursement and transfer controls are intentionally
  // unavailable. Operations uses the weekly internal reconciliation instead.
}

async function enhanceMarketing(data) {
  if (location.hash.slice(1).split("/")[0] !== "marketing") return;
  const section = $(".referral-operations");
  if (!section || $(".referral-flow-status", section)) return;
  const summary = data.reward_operations?.referral_summary || {};
  section.insertAdjacentHTML("beforeend", `<div class="referral-flow-status"><strong>Flujo automático verificado</strong><span>Registro con enlace/código: <b>30 pts al invitador</b></span><span>Primer viaje completado: <b>+70 pts al invitador</b></span><span>Nuevo pasajero: <b>20% en su primer viaje, máximo $40</b></span><span>Cancelación antes de completar: <b>no genera puntos de primer viaje y el descuento vuelve a quedar disponible</b></span><small>Operaciones recibe eventos en tiempo real y conserva el registro en Auditoría. Totales actuales: ${Number(summary.registered || 0)} registros y ${Number(summary.first_trips || 0)} primeros viajes.</small></div>`);
}

async function enhanceAudit() {
  if (location.hash.slice(1).split("/")[0] !== "audit") return;
  const section = $(".commercial-reconciliation");
  if (!section || $(".promotion-commercial-summary", section)) return;
  const report = await rpc("operations_report", periodPayload());
  const commercial = report.commercial_summary || {};
  section.insertAdjacentHTML("beforeend", `<div class="promotion-commercial-summary"><div><small>DESCUENTOS FINANCIADOS POR YAVOI!</small><strong>${money(commercial.promotion_discounts_cents)}</strong><p>${Number(commercial.promotion_free_trips || 0)} viajes gratis en el periodo.</p></div><div><small>AJUSTES COMERCIALES PENDIENTES</small><strong>${money(commercial.promotion_reimbursements_pending_cents)}</strong><p>Operaciones los considera en el corte semanal interno.</p></div><div><small>AJUSTES COMERCIALES CERRADOS</small><strong>${money(commercial.promotion_reimbursements_paid_cents)}</strong><p>Registro comercial conciliado.</p></div><div><small>CONTRIBUCIÓN YAVOI! DESPUÉS DE PROMOCIONES</small><strong>${money(commercial.platform_contribution_after_promotions_cents)}</strong><p>Ingreso comercial generado menos descuentos financiados por la plataforma.</p></div></div>`);
}

async function renderEnhancements(force = false) {
  if (rendering || role !== "admin") return;
  rendering = true;
  try {
    if (force) $$(".promotion-reimbursements,.referral-flow-status,.promotion-commercial-summary").forEach((node) => node.remove());
    const data = await rpc("dashboard");
    await enhancePayments(data);
    await enhanceMarketing(data);
    await enhanceAudit();
  } catch (error) {
    console.error("Operations finance enhancement failed", error);
  } finally {
    rendering = false;
  }
}

function scheduleEnhancement() {
  clearTimeout(renderTimer);
  renderTimer = setTimeout(() => renderEnhancements(), 80);
}

function startReferralAlerts() {
  if (channel || role !== "admin") return;
  channel = db
    .channel(`yavoi-operations-referrals-${crypto.randomUUID()}`)
    .on("postgres_changes", { event: "INSERT", schema: "public", table: "referrals" }, (payload) => {
      notifyOperations(
        "Nuevo referido registrado",
        `El código ${payload.new?.code || "Yavoi!"} quedó ligado a un nuevo pasajero. Se acreditaron 30 puntos al usuario que invitó.`,
        `yavoi-referral-${payload.new?.id || Date.now()}`,
      );
      renderEnhancements(true);
    })
    .on("postgres_changes", { event: "UPDATE", schema: "public", table: "referrals" }, (payload) => {
      if (!payload.old?.first_trip_at && payload.new?.first_trip_at) {
        notifyOperations(
          "Referido completó su primer viaje",
          "Yavoi! acreditó 70 puntos adicionales al usuario que invitó y registró el evento en Auditoría.",
          `yavoi-referral-trip-${payload.new?.id || Date.now()}`,
        );
        renderEnhancements(true);
      }
    })
    .subscribe();
}

async function initialize() {
  try {
    const { data: { user } } = await db.auth.getUser();
    if (!user) return;
    const bootstrap = await rpc("bootstrap");
    role = bootstrap.profile?.role || "";
    if (role !== "admin") return;
    startReferralAlerts();
    scheduleEnhancement();
  } catch {}
}

window.addEventListener("hashchange", scheduleEnhancement);
const observer = new MutationObserver(() => scheduleEnhancement());
observer.observe(document.documentElement, { childList: true, subtree: true });
db.auth.onAuthStateChange((event) => {
  if (event === "SIGNED_OUT") {
    role = "";
    if (channel) db.removeChannel(channel);
    channel = null;
  }
  if (event === "SIGNED_IN") setTimeout(initialize, 0);
});
initialize();
