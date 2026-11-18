// Public summaries contain only the selected trip's operational details.
export function driverRating(value, count) {
  const score = Number(value);
  if (value == null || value === '' || !Number.isFinite(score) || score < 1 || score > 5 || Number(count) === 0) {
    return { label: 'Sin valoraciones', score: null, stars: '☆☆☆☆☆' };
  }
  return { label: `${score.toFixed(2)} de 5`, score, stars: '★'.repeat(Math.round(score)) + '☆'.repeat(5 - Math.round(score)) };
}
export function tripShareText(trip, driver = {}, status = '') {
  const lines = [`Mi viaje con Yavoi! · ${String(trip.id || '').slice(0, 8).toUpperCase()}`,
    `Origen: ${trip.origin || 'Por confirmar'}`, `Destino: ${trip.destination || 'Por confirmar'}`];
  if (driver?.name) lines.push(`Conductor: ${driver.name}`);
  const vehicle = [driver?.vehicle_color, driver?.vehicle_make, driver?.vehicle_model].filter(Boolean).join(' ') || driver?.vehicle;
  if (vehicle) lines.push(`Vehículo: ${vehicle}`);
  if (driver?.plate) lines.push(`Placas: ${driver.plate}`);
  if (status) lines.push(`Estado al compartir: ${status}`);
  lines.push('Este resumen no comparte ubicación en vivo.');
  return lines.join('\n');
}
export function canShareActiveTrip(trip, userId) {
  return Boolean(trip?.driver_id && trip.passenger_id === userId && ['accepted', 'arrived', 'in_progress'].includes(trip.status));
}
