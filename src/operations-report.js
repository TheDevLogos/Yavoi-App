import { escapeHtml as e, money } from "./domain.js";

export const reportNames = Object.freeze({
  overview: "Resumen de operación",
  drivers: "Rendimiento por conductor",
  incidents: "Incidentes y seguimiento",
  ratings: "Valoraciones del servicio",
  insurance: "Pólizas y vencimientos",
  audit: "Registro de cambios",
});
export const periodNames = Object.freeze({
  day: "Hoy",
  week: "Esta semana",
  month: "Este mes",
  year: "Este año",
  custom: "Periodo personalizado",
});
const auditActions = Object.freeze({
  verified_initial_admin: ["Acceso inicial de Operaciones verificado", "Accesos"],
  review_driver: ["Expediente de conductor revisado", "Conductores"],
  driver_dossier_submitted: ["Conductor envió su expediente", "Conductores"],
  driver_insurance_renewed: ["Póliza de seguro renovada", "Documentos"],
  profile_edit_authorized: ["Edición temporal de perfil autorizada", "Accesos"],
  profile_edit_revoked: ["Edición temporal de perfil revocada", "Accesos"],
  category_pricing: ["Tarifa de servicio modificada", "Tarifas"],
  category: ["Categoría de servicio modificada", "Tarifas"],
  review_weekly_fee: ["Cuota semanal revisada", "Pagos"],
  driver_billing_changed: ["Modalidad de cobro del conductor modificada", "Pagos"],
  review_driver_settlement: ["Liquidación de comisión en efectivo revisada", "Pagos"],
  set_driver_access: ["Acceso de conductor modificado", "Accesos"],
  resolve_complaint: ["Reporte atendido", "Incidentes"],
  cancel_trip: ["Viaje cancelado por Operaciones", "Viajes"],
  reward_redemption_fulfilled: ["Recompensa entregada", "Recompensas"],
  reward_redemption_cancelled: ["Canje cancelado y puntos devueltos", "Recompensas"],
  reward_availability_changed: ["Disponibilidad de recompensa modificada", "Recompensas"],
  marketing_settings_changed: ["Sistemas de recompensas y publicidad actualizados", "Promociones"],
  advertising_campaign_saved: ["Promoción guardada", "Promociones"],
  advertising_campaign_status_changed: ["Estado de promoción modificado", "Promociones"],
  privacy_policy_accepted: ["Política de Privacidad aceptada", "Accesos"],
  terms_accepted: ["Términos de Servicio aceptados", "Accesos"],
  operations_report_exported: ["Informe generado", "Informes"],
});
const detailLabels = Object.freeze({
  active: "Cuenta activa",
  approved: "Autorizado",
  allowed_until: "Edición permitida hasta",
  category: "Categoría",
  billing_mode: "Modalidad de cobro",
  weekly_fee_cents: "Aportación semanal",
  cash_commission_bps: "Comisión en efectivo",
  card_commission_bps: "Comisión electrónica",
  commission_due_cents: "Comisión liquidada",
  complete: "Expediente completo",
  driver_id: "Conductor",
  female_verified: "Conductora verificada",
  accessible_verified: "Accesibilidad verificada",
  format: "Formato",
  insurance_expires: "Vigencia de la póliza",
  note: "Nota",
  period: "Periodo",
  reason: "Motivo",
  report: "Informe",
  response: "Respuesta",
  rewards_enabled: "Sistema de Recompensas",
  advertising_enabled: "Publicidad y promociones",
  advertiser_name: "Negocio o anunciante",
  ends_at: "Fin de vigencia",
  title: "Promoción",
  reward_id: "Recompensa",
  reward_id: "Recompensa",
  status: "Estado",
  traffic_law_version: "Versión de obligaciones viales",
  policy_version: "Versión de políticas",
});

export const auditActionInfo = (action = "") =>
  auditActions[action] || [String(action).replaceAll("_", " "), "Otros"];
export const readableAuditValue = (value) => {
  if (typeof value === "boolean") return value ? "Sí" : "No";
  if (value == null || value === "") return "Sin dato";
  if (Array.isArray(value)) return value.map(readableAuditValue).join(", ");
  if (typeof value === "object") return Object.entries(value).map(([key, item]) => `${detailLabels[key] || key}: ${readableAuditValue(item)}`).join(" · ");
  return String(value);
};
export const auditDetailItems = (detail = {}) =>
  Object.entries(detail || {}).map(([key, value]) => ({
    label: detailLabels[key] || key.replaceAll("_", " "),
    value: key.endsWith("_cents") && Number.isFinite(Number(value))
      ? money(Number(value))
      : key.endsWith("_bps") && Number.isFinite(Number(value))
        ? `${Number(value) / 100}%`
        : key === "billing_mode"
          ? ({ weekly_fee: "Aportación semanal", commission: "Comisión por viaje" }[value] || readableAuditValue(value))
          : readableAuditValue(value),
  }));
export const insuranceStatus = (status) => ({
  expired: ["Vencida o faltante", "cancelled"],
  critical: ["Vence en 30 días", "cancelled"],
  warning: ["Vence en 60 días", "pending"],
  valid: ["Vigente", ""],
}[status] || ["Sin estado", "neutral"]);

const shortDate = (value) => value ? new Intl.DateTimeFormat("es-MX", { dateStyle: "medium" }).format(new Date(value)) : "Sin fecha";
const num = (value) => new Intl.NumberFormat("es-MX").format(Number(value || 0));
export const reportPeriodLabel = (meta = {}) => {
  const from = shortDate(meta.from);
  const toDate = meta.to ? new Date(new Date(meta.to).getTime() - 1000) : null;
  return `${periodNames[meta.period] || meta.period || "Periodo"} · ${from} al ${shortDate(toDate)}`;
};

export function reportSections(report = {}, type = "overview") {
  const summary = report.summary || {};
  if (type === "overview") return [
    {
      title: "Indicadores por periodo",
      head: ["Periodo", "Viajes", "Completados", "Ingresos", "Comisión Yavoi!"],
      body: ["day", "week", "month", "year"].map((key) => {
        const item = report.periods?.[key] || {};
        return [periodNames[key], num(item.trips), num(item.completed), money(item.gross_cents), money(item.platform_commission_cents)];
      }),
    },
    {
      title: "Rendimiento de conductores",
      head: ["Conductor", "Viajes", "Ingresos", "Rating", "Incidentes"],
      body: (report.drivers || []).map((item) => [item.full_name, num(item.completed), money(item.gross_cents), item.rating ? `${item.rating}/5` : "Sin datos", num(item.incidents)]),
    },
  ];
  if (type === "drivers") return [{
    title: "Rendimiento individual",
    head: ["Conductor / unidad", "Viajes", "Bruto", "Ingreso conductor", "Comisión", "Rating", "Incidentes"],
    body: (report.drivers || []).map((item) => [`${item.full_name}\n${item.vehicle || "Sin unidad"} · ${item.plate || "Sin placas"}`, num(item.completed), money(item.gross_cents), money(item.driver_earnings_cents), money(item.platform_commission_cents), item.rating ? `${item.rating}/5 (${item.ratings_count})` : "Sin datos", num(item.incidents)]),
  }];
  if (type === "incidents") return [{
    title: "Incidentes registrados",
    head: ["Fecha", "Estado", "Conductor", "Reportó", "Motivo / viaje"],
    body: (report.incidents || []).map((item) => [shortDate(item.created_at), { open: "Abierto", reviewing: "En revisión", resolved: "Resuelto" }[item.status] || item.status, item.driver_name || "Sin conductor", item.reported_by, `${item.subject}\n${item.origin || "Sin viaje"} → ${item.destination || ""}`]),
  }];
  if (type === "ratings") return [{
    title: "Valoraciones recibidas",
    head: ["Fecha", "Conductor", "Calificación", "Comodidad", "Seguridad", "Comentario"],
    body: (report.ratings || []).map((item) => [shortDate(item.created_at), item.driver_name, `${item.stars}/5`, item.comfort || "—", item.safety || "—", item.comment || "Sin comentario"]),
  }];
  if (type === "insurance") return [{
    title: "Control de pólizas",
    head: ["Conductor", "Unidad / placas", "Vigencia", "Días restantes", "Estado", "Documento"],
    body: (report.insurance || []).map((item) => [item.full_name, `${item.vehicle || "Sin unidad"} · ${item.plate || "Sin placas"}`, shortDate(item.insurance_expires), item.days_remaining ?? "—", insuranceStatus(item.status)[0], item.insurance_path ? "PDF registrado" : "Faltante"]),
  }];
  return [{
    title: "Cambios y autorizaciones",
    head: ["Fecha", "Acción", "Responsable", "Área", "Persona o registro afectado", "Detalle"],
    body: (report.audit || []).map((item) => {
      const [label, group] = auditActionInfo(item.action);
      return [shortDate(item.created_at), label, item.actor_name || item.actor_email || "Sin identificar", group, item.target_name || item.target_trip_origin || (item.target_id ? String(item.target_id).slice(0, 8) : "Plataforma"), auditDetailItems(item.detail).map((detail) => `${detail.label}: ${detail.value}`).join(" · ") || "Sin detalle adicional"];
    }),
  }];
}

export async function buildOperationsPdf(report, { type = "overview", logoDataUrl = null } = {}) {
  const [{ jsPDF }, { default: autoTable }] = await Promise.all([
    import("jspdf"),
    import("jspdf-autotable"),
  ]);
  const doc = new jsPDF({ unit: "mm", format: "letter", orientation: type === "overview" ? "portrait" : "landscape" });
  const width = doc.internal.pageSize.getWidth();
  const height = doc.internal.pageSize.getHeight();
  doc.setFillColor(7, 29, 51);
  doc.rect(0, 0, width, 35, "F");
  doc.setTextColor(255, 255, 255);
  doc.setFont("helvetica", "bold");
  doc.setFontSize(18);
  doc.text("Yavoi! Centro de Operaciones", 14, 14);
  doc.setFont("helvetica", "normal");
  doc.setFontSize(10);
  doc.text(reportNames[type] || reportNames.overview, 14, 22);
  doc.setFontSize(8.5);
  doc.text(reportPeriodLabel(report.meta), 14, 29);
  if (logoDataUrl) {
    doc.setFillColor(255, 255, 255);
    doc.roundedRect(width - 50, 5, 40, 25, 3, 3, "F");
    doc.addImage(logoDataUrl, "PNG", width - 47, 6, 34, 23, undefined, "FAST");
  }

  const summary = report.summary || {};
  const kpis = [
    ["Viajes completados", num(summary.completed)],
    ["Ingresos registrados", money(summary.gross_cents)],
    ["Comisión Yavoi!", money(summary.platform_commission_cents)],
    ["Ticket promedio", money(summary.average_ticket_cents)],
    ["Incidentes", num(summary.incidents)],
    ["Rating promedio", summary.average_rating ? `${summary.average_rating}/5` : "Sin datos"],
  ];
  const cols = 3;
  const boxWidth = (width - 28 - 8) / cols;
  kpis.forEach(([label, value], index) => {
    const x = 14 + (index % cols) * (boxWidth + 4);
    const y = 42 + Math.floor(index / cols) * 19;
    doc.setFillColor(246, 249, 252);
    doc.setDrawColor(222, 230, 237);
    doc.roundedRect(x, y, boxWidth, 15, 2, 2, "FD");
    doc.setTextColor(98, 116, 135);
    doc.setFontSize(7.5);
    doc.text(label, x + 3, y + 5);
    doc.setTextColor(7, 29, 51);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(11);
    doc.text(String(value), x + 3, y + 11.5);
    doc.setFont("helvetica", "normal");
  });
  let cursor = 84;
  for (const section of reportSections(report, type)) {
    doc.setTextColor(7, 29, 51);
    doc.setFont("helvetica", "bold");
    doc.setFontSize(11);
    doc.text(section.title, 14, cursor);
    autoTable(doc, {
      startY: cursor + 4,
      head: [section.head],
      body: section.body.length ? section.body : [["Sin registros para este periodo"]],
      margin: { left: 14, right: 14, bottom: 17 },
      styles: { font: "helvetica", fontSize: 7.5, cellPadding: 2.2, overflow: "linebreak", valign: "middle" },
      headStyles: { fillColor: [7, 29, 51], textColor: 255, fontStyle: "bold" },
      alternateRowStyles: { fillColor: [247, 249, 252] },
      didDrawPage: () => {
        doc.setFontSize(7.5);
        doc.setTextColor(115, 129, 145);
        doc.text(`Generado ${new Intl.DateTimeFormat("es-MX", { dateStyle: "medium", timeStyle: "short" }).format(new Date(report.meta?.generated_at || Date.now()))}`, 14, height - 8);
        doc.text(`Página ${doc.getNumberOfPages()}`, width - 14, height - 8, { align: "right" });
      },
    });
    cursor = (doc.lastAutoTable?.finalY || cursor + 15) + 10;
  }
  return doc;
}

export async function imageUrlToDataUrl(url) {
  const response = await fetch(url);
  if (!response.ok) throw Error("No se pudo cargar el logotipo para el informe.");
  const blob = await response.blob();
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(blob);
  });
}

export function reportPrintHtml(report, type = "overview") {
  const sections = reportSections(report, type);
  const summary = report.summary || {};
  const cards = [["Viajes completados", num(summary.completed)], ["Ingresos registrados", money(summary.gross_cents)], ["Comisión Yavoi!", money(summary.platform_commission_cents)], ["Ticket promedio", money(summary.average_ticket_cents)], ["Incidentes", num(summary.incidents)], ["Rating promedio", summary.average_rating ? `${summary.average_rating}/5` : "Sin datos"]];
  return `<!doctype html><html lang="es"><head><meta charset="utf-8"><title>${e(reportNames[type])}</title><style>@page{size:letter;margin:14mm}*{box-sizing:border-box}body{margin:0;font-family:Arial,sans-serif;color:#071d33}header{background:#071d33;color:#fff;padding:20px 24px;display:flex;align-items:center;justify-content:space-between;border-radius:10px}header img{width:115px;background:#fff;border-radius:8px;padding:5px}h1{font-size:22px;margin:0 0 6px}p{margin:0;color:#607185}.period{color:#d9e2e9;font-size:12px}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin:18px 0}.card{border:1px solid #dfe6ed;border-radius:8px;padding:11px}.card small,.card strong{display:block}.card small{color:#718095}.card strong{font-size:17px;margin-top:6px}h2{font-size:16px;margin:22px 0 8px}table{width:100%;border-collapse:collapse;font-size:10px}th{background:#071d33;color:#fff;text-align:left;padding:8px}td{padding:8px;border-bottom:1px solid #e4eaf0;vertical-align:top;white-space:pre-line}tr:nth-child(even){background:#f7f9fc}footer{margin-top:20px;color:#718095;font-size:9px;text-align:center}@media print{button{display:none}header{-webkit-print-color-adjust:exact;print-color-adjust:exact}}</style></head><body><header><div><h1>Yavoi! Centro de Operaciones</h1><div>${e(reportNames[type])}</div><div class="period">${e(reportPeriodLabel(report.meta))}</div></div><img src="/assets/yavoi-logo.png" alt="Yavoi!"></header><div class="cards">${cards.map(([label, value]) => `<div class="card"><small>${e(label)}</small><strong>${e(value)}</strong></div>`).join("")}</div>${sections.map((section) => `<section><h2>${e(section.title)}</h2><table><thead><tr>${section.head.map((cell) => `<th>${e(cell)}</th>`).join("")}</tr></thead><tbody>${section.body.length ? section.body.map((row) => `<tr>${row.map((cell) => `<td>${e(cell)}</td>`).join("")}</tr>`).join("") : `<tr><td colspan="${section.head.length}">Sin registros para este periodo.</td></tr>`}</tbody></table></section>`).join("")}<footer>Informe interno de Yavoi! · Generado ${e(new Intl.DateTimeFormat("es-MX", { dateStyle: "full", timeStyle: "short" }).format(new Date(report.meta?.generated_at || Date.now())))}</footer><script>addEventListener('load',()=>setTimeout(()=>print(),300))<\/script></body></html>`;
}
