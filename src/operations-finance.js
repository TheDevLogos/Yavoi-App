import "./operations-finance.css";
import { db, rpc, money } from "./client.js";

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
  return ({ pending: "Semana abierta", overdue: "Lista para transferir", paid: "Transferido" })[status] || status;
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

function reimbursementCard(item) {
  const transferable = ["overdue"].includes(item.status);
  const details = (item.trips || []).map((trip) =>
    `<li><span>${new Date(trip.completed_at).toLocaleDateString("es-MX", { day: "2-digit", month: "short" })} · ${trip.payment_method === "card" ? "Tarjeta" : "Efectivo"}${trip.free_trip ? " · viaje gratis" : ""}</span><strong>${money(trip.discount_cents)}</strong></li>`,
  ).join("");
  return `<article class="promotion-reimbursement-card"><div><strong>${item.driver_name || "Conductor"}</strong><small>Semana del ${new Date(`${item.week_start}T12:00:00`).toLocaleDateString("es-MX", { dateStyle: "medium" })} · ${item.trip_count} viaje${Number(item.trip_count) === 1 ? "" : "s"} con beneficio</small></div><div class="promotion-reimbursement-total"><small>YAVOI! DEBE REPONER</small><strong>${money(item.reimbursement_cents)}</strong></div><span class="badge ${item.status === "paid" ? "" : "pending"}">${statusName(item.status)}</span><div class="promotion-reimbursement-breakdown"><span>Efectivo <strong>${money(item.cash_discount_cents)}</strong></span><span>Tarjeta <strong>${money(item.card_discount_cents)}</strong></span><span>Viajes gratis <strong>${Number(item.free_trip_count || 0)}</strong></span></div>${details ? `<details><summary>Ver viajes incluidos</summary><ul>${details}</ul></details>` : ""}${transferable ? `<button class="btn" type="button" data-promotion-reimbursement="${item.id}">Registrar transferencia al conductor</button>` : item.status === "paid" ? `<small>Referencia: ${item.transfer_reference || "registrada"} · ${item.paid_at ? new Date(item.paid_at).toLocaleString("es-MX", { dateStyle: "medium", timeStyle: "short" }) : "transferido"}</small>` : `<small>Se cierra y habilita para transferencia al terminar la semana.</small>`}</article>`;
}

function bindReimbursementActions(items) {
  $$('[data-promotion-reimbursement]').forEach((button) => {
    button.onclick = () => {
      const item = items.find((entry) => entry.id === button.dataset.promotionReimbursement);
      if (!item) return;
      const dialog = $("#modal");
      if (!dialog) return;
      dialog.innerHTML = `<button class="close" type="button" aria-label="Cerrar">×</button><h2 id="modal-title">Registrar reembolso promocional</h2><p>Confirma la transferencia de <strong>${money(item.reimbursement_cents)}</strong> a ${item.driver_name}. Este importe corresponde exclusivamente a descuentos y viajes gratis financiados por Yavoi!.</p><form id="promotion-reimbursement-form"><label>Referencia de transferencia<input name="reference" minlength="3" maxlength="160" required placeholder="SPEI, folio bancario o referencia interna"></label><label>Nota de conciliación<textarea name="note" minlength="5" maxlength="1000" required placeholder="Semana y validación realizada"></textarea></label><button class="btn wide" type="submit">Confirmar transferencia</button></form>`;
      $(".close", dialog).onclick = () => dialog.close();
      dialog.showModal();
      $("#promotion-reimbursement-form", dialog).onsubmit = async (event) => {
        event.preventDefault();
        const values = Object.fromEntries(new FormData(event.currentTarget));
        button.disabled = true;
        try {
          await rpc("review_driver_promotion_reimbursement", {
            reimbursement_id: item.id,
            reference: values.reference,
            note: values.note,
          });
          dialog.close();
          toast("Reembolso promocional transferido y registrado en Auditoría.");
          await renderEnhancements(true);
        } catch (error) {
          toast(error.message || "No se pudo registrar la transferencia.");
        } finally {
          button.disabled = false;
        }
      };
    };
  });
}

async function enhancePayments(data) {
  if (location.hash.slice(1).split("/")[0] !== "payments") return;
  const items = data.promotion_reimbursements || [];
  const section = $$('section.panel').find((node) => $("h2", node)?.textContent.trim() === "Liquidaciones de comisión en efectivo");
  if (!section || $(".promotion-reimbursements", section)) return;
  const pending = items.filter((item) => item.status !== "paid");
  const pendingCents = pending.reduce((sum, item) => sum + Number(item.reimbursement_cents || 0), 0);
  section.insertAdjacentHTML("beforeend", `<div class="promotion-reimbursements"><div class="promotion-reimbursement-heading"><div><span class="badge neutral">PROMOCIONES FINANCIADAS POR YAVOI!</span><h3>Reembolsos de descuentos y viajes gratis</h3><p>El conductor conserva su ingreso contractual sobre la tarifa original. Yavoi! acumula semanalmente la diferencia que pagó el usuario y la transfiere al conductor al cierre.</p></div><strong>${money(pendingCents)} pendientes</strong></div><div class="promotion-reimbursement-list">${items.length ? items.map(reimbursementCard).join("") : '<div class="empty"><p>No hay descuentos o viajes gratis completados que requieran reembolso.</p></div>'}</div></div>`);
  bindReimbursementActions(items);
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
  section.insertAdjacentHTML("beforeend", `<div class="promotion-commercial-summary"><div><small>DESCUENTOS FINANCIADOS POR YAVOI!</small><strong>${money(commercial.promotion_discounts_cents)}</strong><p>${Number(commercial.promotion_free_trips || 0)} viajes gratis en el periodo.</p></div><div><small>REEMBOLSOS A CONDUCTORES PENDIENTES</small><strong>${money(commercial.promotion_reimbursements_pending_cents)}</strong><p>Se transfieren al cierre semanal sin reducir su ingreso contractual.</p></div><div><small>REEMBOLSOS YA TRANSFERIDOS</small><strong>${money(commercial.promotion_reimbursements_paid_cents)}</strong><p>Salida de caja promocional conciliada.</p></div><div><small>CONTRIBUCIÓN YAVOI! DESPUÉS DE PROMOCIONES</small><strong>${money(commercial.platform_contribution_after_promotions_cents)}</strong><p>Ingreso comercial generado menos descuentos financiados por la plataforma.</p></div></div>`);
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
    .on("postgres_changes", { event: "*", schema: "public", table: "driver_promotion_reimbursements" }, () => renderEnhancements(true))
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
