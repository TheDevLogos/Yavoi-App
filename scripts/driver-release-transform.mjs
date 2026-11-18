import postcss from 'postcss';
import { parseAst } from 'rolldown/parseAst';

const DRIVER_NAV = `const roles = Object.freeze({ driver: "Conductor" });
const navs = Object.freeze({ driver: [["home", "navigation", "Conducir"], ["trips", "route", "Mis viajes"], ["wallet", "circle-dollar-sign", "Mis ingresos"], ["profile", "user-round", "Mi perfil"]] });
const allowedView = (role, view) => role === "driver" && (navs.driver.some(([id]) => id === view) || ["trip", "help", "inbox", "safety"].includes(view));
`;

const OMITTED_FUNCTIONS = new Set([
  'financialDashboardView', 'downloadWeeklyLiquidationPdf', 'downloadSettlementPdf',
  'commissionPaymentsMarkup', 'paymentsView', 'scheduleOperations',
  'loadScheduleOperations', 'scheduleCalendarMarkup', 'renderScheduleOperations',
  'scheduledConfirmationView', 'openScheduledDay', 'openScheduledTrip',
  'operationsUnitStatus', 'operationsCards', 'operationsListSignature',
  'updateOperationsList', 'updateOperationsMapLayers', 'startOperationsMap',
  'refreshOperationsMap', 'operationsMapView', 'adminHome', 'fleet', 'rates',
  'auditKpis', 'overviewReport', 'driversReport', 'incidentsReport',
  'ratingsReport', 'insuranceReport', 'auditLogReport',
  'transportCompliancePanel', 'renderAuditReport', 'loadOperationsReport',
  'audit', 'bindOperationsReportActions', 'openCampaignEditor',
  'openRewardEditor', 'rewardOperationCard', 'openRewardOperationReview',
  'bindRewardOperationControls', 'openFeatureCardEditor',
  'communicationsPanelMarkup', 'dispatchCommunicationPush',
  'loadCommunicationsHistory', 'marketingView',
  'rewardBarcode', 'rewardImageUrl', 'rewardArtwork', 'openRewardCoupon',
  'rewardEligibility', 'rewardCard', 'rewardHistoryCard', 'rewards',
  'maybeShowRewardPromo', 'maybeShowCampaignPromo', 'maybeShowSchedulePromo',
  'campaignStatus',
]);

const OMITTED_CONSTANTS = new Set([
  'rewardStatusName', 'code128Patterns', 'rewardKindNames',
  'rewardDeliveryNames', 'rewardClaimMethodNames',
]);

const DRIVER_ROUTE = `async function renderRoute() {
  if (!S.profile) return;
  const hash = location.hash.slice(1).split("/");
  S.view = hash[0] || "home";
  if (!allowedView("driver", S.view)) {
    S.view = "home";
    history.replaceState(null, "", "#home");
  }
  if (S.view === "trip") {
    if (!/^[0-9a-f-]{36}$/i.test(hash[1] || "")) {
      location.hash = "trips";
      return;
    }
    await tripView(hash[1]);
  } else if (S.view === "home") await driverHome();
  else if (S.view === "trips") tripsView();
  else if (S.view === "profile") await profile();
  else if (S.view === "wallet") wallet();
  else if (S.view === "inbox") await inbox();
  else if (S.view === "help") help();
  else if (S.view === "safety") safety();
}`;
const DRIVER_WELCOME_FEATURES = `function welcomeFeatureCards() {
  return featureCardsFor("driver").slice(0, 3);
}`;

const DRIVER_FEATURE_CARDS = `function featureCardsFor(audience) {
  if (audience !== "driver") return [];
  const available = S.data.marketing?.feature_cards || [];
  const allowed = new Set(["driver-go-online", "driver-offers", "driver-earnings", "driver-schedule", "driver-safety", "driver-profile", "driver-history"]);
  const matching = available.filter((card) => allowed.has(card.id) && card.audience === "driver" && card.active !== false);
  return (matching.length ? matching : featureCardFallbacks.filter((card) => allowed.has(card.id))).sort((a, b) => Number(a.sort_order) - Number(b.sort_order));
}`;

const DRIVER_INBOX = `async function inbox() {
  const result = await inboxRpc("list");
  const messages = [...(result.messages || [])].filter((item) => ["general", "safety", "payment", "service", "news"].includes(item.category)).sort((a, b) => (Date.parse(b.created_at) || 0) - (Date.parse(a.created_at) || 0));
  const unread = messages.filter((item) => !item.is_read).length;
  const category = { general: "Aviso", safety: "Seguridad", payment: "Pagos", service: "Servicio", news: "Novedades" };
  const cards = messages.length ? messages.map((item) => \`<details class="inbox-message \${item.is_read ? "" : "unread"}" data-inbox-item="\${e(item.id)}"><summary><span class="inbox-category">\${I(item.category === "safety" ? "shield-check" : item.category === "payment" ? "circle-dollar-sign" : "bell")}</span><span class="inbox-message-title"><strong>\${e(item.title)}</strong><small>\${e(category[item.category] || "Aviso")} · \${date(item.created_at)}</small></span>\${item.is_read ? '<span class="badge neutral">Leído</span>' : '<span class="badge pending">Nuevo</span>'}</summary><div class="inbox-message-body">\${item.image_path ? \`<img class="inbox-message-image" src="\${e(featureCardImageUrl(item.image_path))}" alt="Imagen del mensaje">\` : ""}<p>\${e(item.body)}</p>\${item.ends_at ? \`<small>Vigente hasta \${date(item.ends_at)}</small>\` : ""}</div></details>\`).join("") : '<div class="empty"><p>Tu bandeja está al día. Aquí aparecerán los avisos de servicio y de Operaciones.</p></div>';
  shell(\`<div class="inbox-summary panel"><div><div class="eyebrow">MENSAJES Y AVISOS</div><h2>\${unread ? \`\${unread} mensaje\${unread === 1 ? "" : "s"} nuevo\${unread === 1 ? "" : "s"}\` : "Estás al día"}</h2><p>Comunicados de servicio, seguridad y Operaciones.</p></div>\${I("inbox")}</div><section class="panel section-gap"><div class="row between wrap"><div><h2>Bandeja de Entrada</h2><p>Los avisos vigentes se actualizan automáticamente.</p></div><button class="btn secondary" type="button" data-action="refresh">\${I("refresh-cw")} Actualizar</button></div><div class="inbox-list section-gap">\${cards}</div></section>\`, "Bandeja de Entrada", "Mensajes de Yavoi! relacionados con tu cuenta.");
  $$('[data-inbox-item]').forEach((item) => item.addEventListener("toggle", () => {
    if (item.open && item.classList.contains("unread")) run(async () => {
      await inboxRpc("read", { announcement_id: item.dataset.inboxItem });
      item.classList.remove("unread");
      const badge = item.querySelector(".badge");
      if (badge) { badge.className = "badge neutral"; badge.textContent = "Leído"; }
      await refreshUnreadInbox();
    });
  }));
}`;

const DRIVER_FALLBACKS = `const featureCardFallbacks = [
  { id: "driver-go-online", audience: "driver", title: "Conduce a tu ritmo", summary: "Conéctate durante tu turno y controla tu disponibilidad.", body: "Activa tu disponibilidad cuando estés listo para recibir solicitudes. Puedes desconectarte cuando termines y actualizar tu ubicación mientras estás conectado.", image_path: "/assets/feature-cards/driver-go-online.png", cta_label: "Ir a Conducir", cta_href: "#home", sort_order: 10 },
  { id: "driver-offers", audience: "driver", title: "Decide cada oferta", summary: "Consulta origen, destino, pago y ganancia antes de aceptar.", body: "Revisa el servicio, las indicaciones, la distancia para recoger y el importe antes de decidir.", image_path: "/assets/feature-cards/driver-offers.png", cta_label: "Ver solicitudes", cta_href: "#home", sort_order: 20 },
  { id: "driver-earnings", audience: "driver", title: "Tu corte, claro", summary: "Consulta tus servicios, comisiones y cuota semanal.", body: "El corte reúne el detalle comercial de tus viajes. Operaciones conserva la conciliación semanal.", image_path: "/assets/feature-cards/driver-earnings.png", cta_label: "Ver corte semanal", cta_href: "#wallet", sort_order: 30 },
  { id: "driver-schedule", audience: "driver", title: "Organiza tu jornada", summary: "Conoce el turno y mantén tu disponibilidad al día.", body: "Tu turno asignado se muestra al conectarte. Mantener tu perfil y presencia actualizados ayuda a recibir solicitudes compatibles.", image_path: "/assets/feature-cards/driver-schedule.png", cta_label: "Ver mi jornada", cta_href: "#home", sort_order: 40 },
  { id: "driver-safety", audience: "driver", title: "Conduce con respaldo", summary: "Consulta las pautas de seguridad y registra incidentes.", body: "Revisa los datos del viaje antes de aceptarlo y usa el reporte dentro de la aplicación si surge una situación que Operaciones deba atender.", image_path: "/assets/feature-cards/driver-safety.png", cta_label: "Ver seguridad", cta_href: "#safety", sort_order: 50 },
  { id: "driver-profile", audience: "driver", title: "Expediente siempre al día", summary: "Mantén documentos, unidad y datos de operación actualizados.", body: "Tu perfil concentra licencia, seguro, vehículo y datos requeridos por Operaciones.", image_path: "/assets/feature-cards/driver-profile.png", cta_label: "Abrir mi perfil", cta_href: "#profile", sort_order: 60 },
  { id: "driver-history", audience: "driver", title: "Cada viaje cuenta", summary: "Consulta historial, folios y detalle de servicios completados.", body: "Mis viajes conserva la información operativa de tus traslados.", image_path: "/assets/feature-cards/driver-history.png", cta_label: "Abrir Mis viajes", cta_href: "#trips", sort_order: 70 },
];`;

function walk(node, visit) {
  if (!node || typeof node !== 'object') return;
  if (Array.isArray(node)) {
    for (const item of node) walk(item, visit);
    return;
  }
  if (typeof node.type === 'string') visit(node);
  for (const [key, value] of Object.entries(node)) {
    if (key === 'loc' || key === 'start' || key === 'end') continue;
    if (Array.isArray(value)) walk(value, visit);
    else if (value && typeof value === 'object') walk(value, visit);
  }
}

function roleMember(node) {
  if (node?.type === 'ChainExpression') node = node.expression;
  if (!node || node.type !== 'MemberExpression' || node.computed || node.property?.name !== 'role') return null;
  const object = node.object;
  if (object?.type === 'MemberExpression' && !object.computed && object.object?.name === 'S' && object.property?.name === 'profile') return 'driver';
  if (object?.type === 'Identifier' && object.name === 'p') return 'profile-alias';
  return null;
}

function foldedRoleComparison(node, scope) {
  if (node.type !== 'BinaryExpression' || !['===', '!==', '==', '!='].includes(node.operator)) return null;
  const check = (member, literal) => {
    if (literal?.type !== 'Literal' || typeof literal.value !== 'string') return null;
    const kind = roleMember(member);
    if (!kind || (kind === 'profile-alias' && !['profile', 'shell'].includes(scope))) return null;
    const matches = literal.value === 'driver';
    return String(node.operator === '===' || node.operator === '==' ? matches : !matches);
  };
  return check(node.left, node.right) ?? check(node.right, node.left);
}

function driverPortal(code) {
  const referralStart = code.indexOf('const referralFromUrl = ');
  const referralEnd = referralStart < 0 ? -1 : code.indexOf('const modal = ', referralStart);
  if (referralStart >= 0 && referralEnd > referralStart)
    code = code.slice(0, referralStart) + code.slice(referralEnd);
  code = code.replace(/\s*referralCode: "",?\s*/g, ' ');
  code = code.replace(/\$\{targetRole !== "driver" \? `<label>Código de invitación[\s\S]*?<\/label>` : ""\}/g, '');
  code = code.replace(/\s*const referralCode = String\(v\.referral_code \|\| ""\)\.trim\(\)\.toUpperCase\(\);\s*if \(referralCode\) \{\s*S\.referralCode = referralCode;\s*try \{ localStorage\.setItem\("yavoi-referral-code", referralCode\); \} catch \{\}\s*\}\s*/g, '\n');
  code = code.replace(/<label id="onboard-referral"[\s\S]*?<\/label>/g, '');
  code = code.replace(/\s*\$\$\('#onboard input\[name="role"\]'\)\.forEach\(\(input\) => input\.onchange = \(\) => \{\s*\$\("#onboard-referral"\)\.classList\.toggle\("hidden", input\.value === "driver" && input\.checked\);\s*\}\);\s*/g, '\n');
  code = code.replace('await rpc("onboard", { ...v, referral_code: v.role === "passenger" ? String(v.referral_code || "").trim().toUpperCase() : "" });', 'await rpc("onboard", { ...v });');
  code = code.replace(/\s*try \{ localStorage\.removeItem\("yavoi-referral-code"\); \} catch \{\}\s*S\.referralCode = "";\s*/g, '\n');
  code = code.replace(/,\s*"advertising_interest"/g, '');
  code = code.replace('<label class="check"><input type="checkbox" name="advertising_interest" ${d.advertising_interest ? "checked" : ""}>Me interesa participar en convenios de publicidad</label>', '');
  code = code.replace(/\s*advertising_interest: v\.advertising_interest === "on",/g, '');
  code = code.replace(/\s*\.on\("postgres_changes", \{ event: "INSERT", schema: "public", table: "reward_entries"[^\n]*\n/g, '\n');
  code = code.replace(/\s*\.on\("postgres_changes", \{ event: "\*", schema: "public", table: "reward_redemptions"[^\n]*\n/g, '\n');
  code = code.replace(/^\s*else if \(S\.view === "rewards"\) await refreshPage\(\);\s*\n/gm, '\n');
  code = code.replace(/\^\(home\|rewards\|trips\|profile\|schedule\|inbox\)\$/g, '^(home|trips|profile|schedule|inbox)$');
  code = code.replace('Confirmo que el viaje cubierto por la recompensa llegó al destino.', 'Confirmo que el importe está cubierto y no se recibió efectivo.');
  code = code.replace(/const rewardPaymentRow = t\.reward_discount_cents[\s\S]*?\n\s*: "";/, 'const rewardPaymentRow = "";');
  code = code.replace(/\$\{trip\.reward_discount_cents \? `<div class="receipt-row positive-points">[\s\S]*?<\/div>` : ""\}/g, '');
  code = code.replace(/\$\{t\.reward_discount_cents \? `<div class="receipt-row positive-points"><span>Descuento aplicado<\/span><strong>-\$\{money\(t\.reward_discount_cents\)\}<\/strong><\/div>` : ""\}/g, '');
  code = code.replace('Incluye promociones por conciliar. Consulta la comisión y los ajustes del servicio en el desglose.', 'Consulta la comisión y los ajustes del servicio en el desglose.');
  code = code.replace('name: "Novedades, promociones y consejos", description: "Promociones, herramientas y recomendaciones de Yavoi!"', 'name: "Avisos y consejos", description: "Consejos de servicio y seguridad de Yavoi!"');
  code = code.replace('Recibirás solicitudes, promociones, consejos y avisos de seguridad cuando la app esté en segundo plano.', 'Recibirás solicitudes, consejos y avisos de seguridad cuando la app esté en segundo plano.');
  code = code.replace('<div class="notification-switch-row"><span><strong>Promociones y consejos</strong><small>Opcionales · puedes apagarlos cuando quieras</small></span><button type="button" role="switch" aria-label="Promociones y consejos" aria-checked="${S.marketingPushEnabled}" class="yavoi-switch" data-push-preference="marketing_enabled"><span></span></button></div>', '');
  code = code.replace(/\s*\["gift", "Recompensas y referidos", "Consulta beneficios, invitaciones y movimientos de recompensas\.", admin \? "marketing" : "rewards", "Ver recompensas"\],?\s*/g, '\n');
  code = code.replace('<option>Recompensas o referidos</option>', '');
  const ast = parseAst(code);
  const edits = [];
  let firstExecutable = null;
  for (const node of ast.body) {
    if (node.type === 'ImportDeclaration') continue;
    if (firstExecutable === null) firstExecutable = node.start;
  }
  for (const node of ast.body) {
    if (node.type === 'VariableDeclaration' && node.declarations.some((item) => item.id?.name === 'featureCardFallbacks')) {
      edits.push({ start: node.start, end: node.end, value: DRIVER_FALLBACKS });
      continue;
    }
    if (node.type === 'VariableDeclaration' && node.declarations.some((item) => OMITTED_CONSTANTS.has(item.id?.name))) {
      edits.push({ start: node.start, end: node.end, value: '' });
      continue;
    }
    if (node.type === 'ImportDeclaration') {
      const source = node.source?.value;
      if (source === './release-features.js') {
        edits.push({ start: node.start, end: node.end, value: '' });
        continue;
      }
      if (['./operations-attention.js', './operations-report.js', './finance-dashboard.js'].includes(source)) {
        edits.push({ start: node.start, end: node.end, value: '' });
        continue;
      }
      if (source === './finance.js') {
        const keep = node.specifiers.filter((specifier) => specifier.imported?.name !== 'mountFinanceOperations');
        const names = keep.map((specifier) => {
          const imported = specifier.imported?.name || specifier.imported?.value;
          const local = specifier.local?.name;
          return imported === local ? imported : `${imported} as ${local}`;
        });
        edits.push({ start: node.start, end: node.end, value: `import { ${names.join(', ')} } from "./finance.js";` });
        continue;
      }
    }
    if (node.type !== 'FunctionDeclaration' || !node.id?.name) continue;
    const name = node.id.name;
    if (OMITTED_FUNCTIONS.has(name)) {
      edits.push({ start: node.start, end: node.end, value: '' });
      continue;
    }
    if (name === 'renderRoute') {
      edits.push({ start: node.start, end: node.end, value: DRIVER_ROUTE });
      continue;
    }
    if (name === 'featureCardsFor') {
      edits.push({ start: node.start, end: node.end, value: DRIVER_FEATURE_CARDS });
      continue;
    }
    if (name === 'inbox') {
      edits.push({ start: node.start, end: node.end, value: DRIVER_INBOX });
      continue;
    }
    if (name === 'welcomeFeatureCards') {
      edits.push({ start: node.start, end: node.end, value: DRIVER_WELCOME_FEATURES });
      continue;
    }
    walk(node, (child) => {
      // The Operations module is deliberately absent from Drive. Its session
      // cleanup must be removed too, or unauthenticated startup throws before login.
      if (child.type === 'CallExpression' && child.callee?.type === 'Identifier' && child.callee.name === 'stopOperationsAttention') {
        edits.push({ start: child.start, end: child.end, value: 'void 0' });
        return;
      }
      if (child.type === 'CallExpression' && child.callee?.type === 'Identifier' && child.callee.name === 'rewardsEnabledFor') {
        edits.push({ start: child.start, end: child.end, value: 'false' });
        return;
      }
      const folded = foldedRoleComparison(child, name);
      if (folded !== null) edits.push({ start: child.start, end: child.end, value: folded });
    });
  }

  const domainImport = ast.body.find((node) => node.type === 'ImportDeclaration' && node.source?.value === './domain.js');
  if (!domainImport) throw new Error('Driver build could not locate the domain import.');
  const omit = new Set(['roles', 'navs', 'allowedView']);
  const keep = domainImport.specifiers.filter((specifier) => {
    const imported = specifier.imported?.name || specifier.imported?.value;
    return !omit.has(imported) && !['rewardEligibleForTrip', 'rewardDiscountCents'].includes(imported);
  });
  const names = keep.map((specifier) => {
    const imported = specifier.imported?.name || specifier.imported?.value;
    const local = specifier.local?.name;
    return imported === local ? imported : `${imported} as ${local}`;
  });
  edits.push({ start: domainImport.start, end: domainImport.end, value: `import { ${names.join(', ')} } from "./domain.js";` });

  if (firstExecutable === null) throw new Error('Driver build could not locate portal code.');
  edits.push({ start: firstExecutable, end: firstExecutable, value: DRIVER_NAV });
  edits.sort((a, b) => b.start - a.start || b.end - a.end);
  let output = code;
  for (const edit of edits) output = output.slice(0, edit.start) + edit.value + output.slice(edit.end);
  return output;
}

function driverStyles(code, adminFinance = false) {
  const root = postcss.parse(code);
  root.walkRules((rule) => {
    const kept = rule.selectors.filter((selector) => {
      if (adminFinance && /\.finance-(?:operations|action-list|action-item|warning-context|warning-list)\b/.test(selector)) return false;
      if (!adminFinance && /\.[\w-]*(?:reward|recompens|referr|campaign|market|promo|advert)[\w-]*/i.test(selector)) return false;
      return true;
    });
    if (!kept.length) rule.remove();
    else if (kept.length !== rule.selectors.length) rule.selectors = kept;
  });
  return root.toString();
}

function driverFinance(code) {
  return code
    .replace("${trip.reward_discount_cents ? row('Descuento aplicado', -trip.reward_discount_cents) : ''}", '')
    .replace("${finance.promotion_pending_cents ? row('Descuento financiado por Yavoi!', finance.promotion_pending_cents) : ''}", '');
}

function driverTerms(html) {
  return html
    .replace('<a href="#recompensas">Recompensas</a>', '')
    .replace(/\s*<section class="legal-section" id="recompensas">[\s\S]*?<\/section>/, '')
    .replace('<h2>10. Reportes, revisión y suspensión</h2>', '<h2>9. Reportes, revisión y suspensión</h2>')
    .replace('<h2>11. Disponibilidad, responsabilidad y terceros</h2>', '<h2>10. Disponibilidad, responsabilidad y terceros</h2>')
    .replace('<h2>12. Terminación, cambios, ley y contacto</h2>', '<h2>11. Terminación, cambios, ley y contacto</h2>')
    .replace('descuentos y propina voluntaria', 'propina voluntaria')
    .replace('espera extraordinaria, promociones y conceptos informados antes de concluir', 'espera extraordinaria y ajustes informados y aceptados antes de concluir');
}

function driverPrivacy(html) {
  return html
    .replace('<li>Puntos, recompensas, cupones, promociones, códigos de invitación y el cumplimiento del registro y primer viaje de las personas invitadas.</li>', '')
    .replace('<li>Administrar recompensas, invitaciones verificadas, calidad, desempeño y soporte.</li>', '<li>Administrar calidad, desempeño, avisos de servicio y soporte.</li>')
    .replace('<p>Con consentimiento o cuando la ley lo permita, podremos mostrar promociones, recompensas y comunicaciones de comercios participantes. Puedes dejar de participar sin perder las funciones esenciales del servicio.</p>', '')
    .replace('No vendemos datos de Google, no los usamos para publicidad personalizada, perfiles crediticios ni entrenamiento de modelos de inteligencia artificial.', 'No vendemos datos de Google ni los usamos para perfiles crediticios o entrenamiento de modelos de inteligencia artificial.');
}

export function driverReleasePlugin() {
  return {
    name: 'yavoi-driver-release-scope',
    enforce: 'pre',
    transform(code, id) {
      const filename = id.split('?')[0];
      if (filename.endsWith('/src/portal.js')) return { code: driverPortal(code), map: null };
      if (filename.endsWith('/src/portal.css')) return { code: driverStyles(code), map: null };
      if (filename.endsWith('/src/finance.js')) return { code: driverFinance(code), map: null };
      if (filename.endsWith('/src/finance.css')) return { code: driverStyles(code, true), map: null };
      return null;
    },
    transformIndexHtml: {
      order: 'pre',
      handler(html, context) {
        if (context?.filename?.endsWith('terminos.html')) return driverTerms(html);
        if (context?.filename?.endsWith('privacidad.html')) return driverPrivacy(html);
        if (!context?.filename?.endsWith('portal.html')) return html;
        return html
          .replace(/<script\b[^>]*src=["']\/src\/operations-finance\.js["'][^>]*><\/script>/g, '')
          .replace('name="description" content="Accede a tu cuenta Yavoi! Solicita viajes o administra tu actividad como conductor."', 'name="description" content="Gestiona tus viajes, recibe solicitudes y navega como conductor autorizado de Yavoi!."')
          .replace('name="apple-mobile-web-app-title" content="Yavoi!"', 'name="apple-mobile-web-app-title" content="Yavoi! Drive"')
          .replace('<title>Mi Yavoi! · Tu raite, al instante</title>', '<title>Yavoi! Drive · Conductores</title>');
      },
    },
  };
}

export const driverReleaseInternals = Object.freeze({ driverPortal, driverStyles });
