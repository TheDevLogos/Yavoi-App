import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  fallbackStreetRoute,
  routeMeasurements,
  routePosition,
  travelledPoints
} from '../src/landing-route.js';

const landing = await readFile(new URL('../app.js', import.meta.url), 'utf8');
const html = await readFile(new URL('../index.html', import.meta.url), 'utf8');

test('landing vehicle advances at a constant distance along unequal street segments', () => {
  const points = [[0, 0], [0, .001], [0, .004]];
  const measurements = routeMeasurements(points);
  const halfway = routePosition(points, measurements, .5);
  assert.equal(halfway.index, 2);
  assert.ok(Math.abs(halfway.point[1] - .002) < .00002);
  assert.deepEqual(travelledPoints(points, halfway), [[0, 0], [0, .001], halfway.point]);
});

test('landing route fallback uses street-like right-angle segments', () => {
  const start = [28.19, -105.48];
  const end = [28.18, -105.45];
  const route = fallbackStreetRoute(start, end);
  assert.deepEqual(route[0], start);
  assert.deepEqual(route.at(-1), end);
  assert.equal(route[1][0], start[0]);
  assert.equal(route[1][1], route[2][1]);
  assert.equal(route[2][0], end[0]);
});

test('every animated landing map uses a road route, direction and travelled trace', () => {
  assert.match(landing, /router\.project-osrm\.org\/route\/v1\/driving/);
  assert.match(landing, /overview=full&geometries=geojson/);
  assert.match(landing, /function rotateMarker/);
  assert.match(landing, /routeMeasurements\(points\)/);
  assert.match(landing, /traceLine\?\.setLatLngs\(travelledPoints/);
  assert.equal((landing.match(/setupLoopMap\('/g) || []).length, 3);
  assert.match(landing, /animateMarker\(riderCar, approach,[\s\S]{0,160}traceLine:riderTraceLine/);
  assert.match(landing, /animateMarker\(riderCar, points,[\s\S]{0,160}traceLine:riderTraceLine/);
  assert.match(landing, /animateMarker\(driverCar, approach,[\s\S]{0,160}traceLine:driverTraceLine/);
  assert.match(landing, /animateMarker\(driverCar, trip,[\s\S]{0,160}traceLine:driverTraceLine/);
  assert.match(html, /Ruta demostrativa trazada sobre calles reales/);
});
