export function routeKey(a, b) {
  return [...a, ...b].map(value => Number(value).toFixed(5)).join(':');
}

export function fallbackStreetRoute(a, b) {
  const middleLng = a[1] + (b[1] - a[1]) * .52;
  return [a, [a[0], middleLng], [b[0], middleLng], b];
}

export function distanceMeters(a, b) {
  const toRadians = value => value * Math.PI / 180;
  const lat1 = toRadians(a[0]);
  const lat2 = toRadians(b[0]);
  const deltaLat = lat2 - lat1;
  const deltaLng = toRadians(b[1] - a[1]);
  const value = Math.sin(deltaLat / 2) ** 2 + Math.cos(lat1) * Math.cos(lat2) * Math.sin(deltaLng / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(value), Math.sqrt(1 - value));
}

export function routeMeasurements(points) {
  const cumulative = [0];
  for (let index = 1; index < points.length; index += 1) {
    cumulative.push(cumulative[index - 1] + distanceMeters(points[index - 1], points[index]));
  }
  return { cumulative, total:cumulative[cumulative.length - 1] || 1 };
}

export function routePosition(points, measurements, progress) {
  const target = measurements.total * Math.max(0, Math.min(1, progress));
  let index = 1;
  while (index < measurements.cumulative.length - 1 && measurements.cumulative[index] < target) index += 1;
  const a = points[index - 1];
  const b = points[index];
  const start = measurements.cumulative[index - 1];
  const segmentDistance = Math.max(1, measurements.cumulative[index] - start);
  const local = Math.max(0, Math.min(1, (target - start) / segmentDistance));
  return {
    point:[a[0] + (b[0] - a[0]) * local, a[1] + (b[1] - a[1]) * local],
    index,
    heading:Math.atan2(b[1] - a[1], b[0] - a[0]) * 180 / Math.PI
  };
}

export function travelledPoints(points, position) {
  return [...points.slice(0, position.index), position.point];
}
