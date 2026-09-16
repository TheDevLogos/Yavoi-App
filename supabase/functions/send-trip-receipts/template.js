const TIME_ZONE = "America/Chihuahua";

const htmlEscape = (value) => String(value ?? "")
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;")
  .replaceAll('"', "&quot;")
  .replaceAll("'", "&#39;");

const dateValue = (value, options) => new Intl.DateTimeFormat("es-MX", {
  timeZone: TIME_ZONE,
  ...options,
}).format(new Date(value));

const money = (cents) => new Intl.NumberFormat("es-MX", {
  style: "currency",
  currency: "MXN",
}).format(Number(cents || 0) / 100);

export function buildReceiptContent(payload) {
  const trip = payload?.trip || {};
  const driver = payload?.driver || {};
  const required = [
    payload?.trip_id, payload?.recipient_email, trip.started_at, trip.completed_at,
    trip.origin, trip.destination, driver.name, driver.photo_path,
  ];
  if (required.some((value) => !String(value ?? "").trim())) throw new Error("El recibo está incompleto.");
  const email = String(payload.recipient_email).trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || /[\r\n]/.test(email)) throw new Error("Correo de destino inválido.");
  const distance = Math.max(0, Number(trip.distance_km || 0));
  const duration = Math.max(0, Math.round(Number(trip.duration_minutes || 0)));
  const folio = String(payload.receipt_number || `YV-${String(payload.trip_id).replaceAll("-", "").slice(0, 12)}`).toUpperCase();
  const rideDate = dateValue(trip.started_at, { dateStyle: "long" });
  const startTime = dateValue(trip.started_at, { hour: "2-digit", minute: "2-digit", hour12: true });
  const endTime = dateValue(trip.completed_at, { hour: "2-digit", minute: "2-digit", hour12: true });
  const distanceNote = trip.distance_source === "gps" ? "Recorrido GPS registrado" : "Ruta resguardada del servicio";
  const subject = `Recibo de viaje Yavoi! · ${folio}`;
  const html = `<!doctype html><html lang="es"><head><meta charset="utf-8"></head><body style="margin:0;background:#f3f6f8;font-family:Arial,sans-serif;color:#071d33"><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:#f3f6f8;padding:24px 12px"><tr><td align="center"><table role="presentation" width="620" cellspacing="0" cellpadding="0" style="max-width:620px;width:100%;background:#fff;border-radius:20px;overflow:hidden;border:1px solid #dde5eb"><tr><td style="background:#071d33;padding:28px;color:#fff"><div style="font-size:30px;font-weight:800">Yav<span style="color:#ff6500">o</span>i!</div><div style="margin-top:5px;color:#c7d4df">Tu raite, al instante</div></td></tr><tr><td style="padding:30px"><div style="font-size:12px;letter-spacing:1.5px;color:#e75c00;font-weight:700">COMPROBANTE DE SERVICIO</div><h1 style="font-size:25px;margin:8px 0 4px">Gracias por viajar con Yavoi!</h1><p style="margin:0 0 24px;color:#64748b">Folio ${htmlEscape(folio)}</p><table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-collapse:collapse"><tr><td style="padding:12px 0;border-bottom:1px solid #e5eaf0;color:#64748b">Fecha del viaje</td><td align="right" style="padding:12px 0;border-bottom:1px solid #e5eaf0;font-weight:700">${htmlEscape(rideDate)}</td></tr><tr><td style="padding:12px 0;border-bottom:1px solid #e5eaf0;color:#64748b">Hora de inicio</td><td align="right" style="padding:12px 0;border-bottom:1px solid #e5eaf0;font-weight:700">${htmlEscape(startTime)}</td></tr><tr><td style="padding:12px 0;border-bottom:1px solid #e5eaf0;color:#64748b">Hora de finalización</td><td align="right" style="padding:12px 0;border-bottom:1px solid #e5eaf0;font-weight:700">${htmlEscape(endTime)}</td></tr><tr><td style="padding:12px 0;border-bottom:1px solid #e5eaf0;color:#64748b">Duración total</td><td align="right" style="padding:12px 0;border-bottom:1px solid #e5eaf0;font-weight:700">${duration} min</td></tr><tr><td style="padding:12px 0;border-bottom:1px solid #e5eaf0;color:#64748b">Distancia recorrida</td><td align="right" style="padding:12px 0;border-bottom:1px solid #e5eaf0;font-weight:700">${distance.toFixed(2)} km<br><small style="color:#8795a5;font-weight:400">${htmlEscape(distanceNote)}</small></td></tr></table><div style="margin:24px 0;padding:18px;background:#f6f8fa;border-radius:14px"><div style="font-size:12px;color:#64748b">PUNTO DE INICIO</div><strong style="display:block;margin:5px 0 14px">${htmlEscape(trip.origin)}</strong><div style="font-size:12px;color:#64748b">DESTINO</div><strong style="display:block;margin-top:5px">${htmlEscape(trip.destination)}</strong></div><table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td width="76"><img src="cid:driver-photo" width="62" height="62" alt="Fotografía del conductor ${htmlEscape(driver.name)}" style="display:block;border-radius:50%;object-fit:cover;border:3px solid #fff;box-shadow:0 2px 10px #cbd5e1"></td><td><div style="font-size:12px;color:#64748b">CONDUCTOR</div><strong style="font-size:18px">${htmlEscape(driver.name)}</strong></td></tr></table><div style="margin-top:26px;padding-top:20px;border-top:2px solid #071d33;display:flex"><span style="font-size:17px;font-weight:700">Total cobrado</span><strong style="margin-left:auto;font-size:25px;color:#e75c00">${htmlEscape(money(trip.total_cents))}</strong></div><p style="margin:26px 0 0;color:#64748b;font-size:12px;line-height:1.5">Este comprobante corresponde al servicio de transporte registrado en Yavoi! y no sustituye una factura fiscal.</p></td></tr></table></td></tr></table></body></html>`;
  const text = [
    "Yavoi! · Tu raite, al instante", `Recibo ${folio}`, `Fecha: ${rideDate}`,
    `Inicio: ${startTime}`, `Finalización: ${endTime}`, `Duración: ${duration} min`,
    `Distancia: ${distance.toFixed(2)} km (${distanceNote})`, `Origen: ${trip.origin}`,
    `Destino: ${trip.destination}`, `Conductor: ${driver.name}`, `Total cobrado: ${money(trip.total_cents)}`,
  ].join("\n");
  return { email, subject, html, text, driverPhotoPath: String(driver.photo_path), folio };
}

