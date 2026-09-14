import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.116.0";

const json = (body: unknown, status: number, origin: string) => new Response(JSON.stringify(body), {
  status,
  headers: {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "private, max-age=300",
    "access-control-allow-origin": origin,
    "access-control-allow-headers": "authorization, apikey, content-type, x-client-info",
    "access-control-allow-methods": "POST, OPTIONS",
    vary: "Origin",
  },
});

function originFor(req: Request) {
  const origin = req.headers.get("origin") || "";
  const allowed = (Deno.env.get("APP_ORIGINS") || "https://yavoi-delicias.alonsovl-logos88.chatgpt.site,https://yavoi-app.vercel.app").split(",").map((v) => v.trim());
  return allowed.includes(origin) || /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(origin) ? origin : "";
}

const insideCoverage = (lat: number, lng: number) => lat >= 28 && lat <= 28.4 && lng >= -105.7 && lng <= -105.2;

function addressLabel(item: Record<string, unknown>) {
  const address = item.address && typeof item.address === "object" ? item.address as Record<string, unknown> : {};
  const street = String(address.road || address.pedestrian || address.residential || address.neighbourhood || "").trim();
  const number = String(address.house_number || "").trim();
  const locality = String(address.city || address.town || address.village || address.municipality || "Delicias").trim();
  const place = String(item.name || address.amenity || address.shop || address.tourism || "").trim();
  if (street) return [street, number, locality].filter(Boolean).join(" ");
  if (place) return [place, locality].filter(Boolean).join(", ");
  return String(item.display_name || "Ubicación seleccionada");
}

function nominatimHeaders() {
  return { "user-agent": "Yavoi/1.1 (+https://yavoi-app.vercel.app/)", "accept-language": "es-MX,es;q=0.9" };
}

const streetNumbers: Record<string, number> = {
  uno: 1, una: 1, primero: 1, dos: 2, segundo: 2, tres: 3, tercero: 3, cuatro: 4,
  cinco: 5, seis: 6, siete: 7, ocho: 8, nueve: 9, diez: 10, once: 11, doce: 12,
  trece: 13, catorce: 14, quince: 15, dieciseis: 16, diecisiete: 17, dieciocho: 18,
  diecinueve: 19, veinte: 20, veintiuno: 21, veintidos: 22, veintitres: 23,
  veinticuatro: 24, veinticinco: 25, veintiseis: 26, veintisiete: 27, veintiocho: 28,
  veintinueve: 29, treinta: 30,
};

function plainWord(value: string) {
  return value.normalize("NFD").replace(/\p{Diacritic}/gu, "").toLocaleLowerCase("es-MX");
}

function addressQueryVariants(value: string) {
  const original = value.trim().replace(/\s+/g, " ");
  const fraction = original.replace(/(\d)\s*½/g, "$1 1/2");
  const numeric = fraction.replace(
    /\b(calle|avenida|av\.?|privada|priv\.?|calzada)\s+(uno|una|primero|dos|segundo|tres|tercero|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|trece|catorce|quince|diecis[eé]is|diecisiete|dieciocho|diecinueve|veinte|veintiuno|veintid[oó]s|veintitr[eé]s|veinticuatro|veinticinco|veintis[eé]is|veintisiete|veintiocho|veintinueve|treinta)(\s+y\s+media)?\b/gi,
    (_match, prefix: string, numberWord: string, half: string) =>
      `${prefix} ${streetNumbers[plainWord(numberWord)]}${half ? " 1/2" : ""}`,
  );
  const compactHalf = numeric.replace(/(\d+)\s+1\/2/g, "$1½");
  const decimalHalf = numeric.replace(/(\d+)\s+1\/2/g, (_match, number) => String(Number(number) + 0.5));
  return [...new Set([numeric, compactHalf, decimalHalf, original])].slice(0, 4);
}

function localAddressQuery(query: string) {
  return /\b(delicias|meoqui)\b/i.test(query)
    ? `${query}, Chihuahua, México`
    : `${query}, Delicias, Chihuahua, México`;
}

Deno.serve(async (req: Request) => {
  const origin = originFor(req);
  if (!origin) return json({ error: "Origen no permitido." }, 403, "null");
  if (req.method === "OPTIONS") return json({ ok: true }, 200, origin);
  if (req.method !== "POST") return json({ error: "Método no permitido." }, 405, origin);
  try {
    const authorization = req.headers.get("authorization") || "";
    const userClient = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_ANON_KEY") || "", { global: { headers: { Authorization: authorization } } });
    const serviceClient = createClient(Deno.env.get("SUPABASE_URL") || "", Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "", { auth: { persistSession: false } });
    const { data: authData, error: authError } = await userClient.auth.getUser();
    if (authError || !authData.user) return json({ error: "Sesión no válida." }, 401, origin);
    const body = await req.json();
    const type = body?.type;
    let key = "";
    if (type === "search") {
      const query = String(body.query || "").trim().replace(/\s+/g, " ");
      if (query.length < 3 || query.length > 160) return json({ error: "Escribe al menos tres caracteres." }, 400, origin);
      key = `search:v3:${plainWord(query)}`;
      const { data: cached } = await serviceClient.rpc("yavoi_map_cache_get", { key_value: key });
      if (cached) return json(cached, 200, origin);
      const { data: permitted } = await serviceClient.rpc("yavoi_map_rate_limit", { target_user: authData.user.id });
      if (!permitted) return json({ error: "Espera un segundo antes de buscar otra dirección." }, 429, origin);
      let raw: Record<string, unknown>[] = [];
      for (const variant of addressQueryVariants(query)) {
        const params = new URLSearchParams({ format: "jsonv2", q: localAddressQuery(variant), countrycodes: "mx", viewbox: "-105.7,28.4,-105.2,28.0", bounded: "1", limit: "10", addressdetails: "1", dedupe: "1" });
        const upstream = await fetch(`https://nominatim.openstreetmap.org/search?${params}`, { headers: nominatimHeaders() });
        if (!upstream.ok) throw new Error("El buscador de direcciones no respondió.");
        raw = await upstream.json();
        if (raw.length) break;
      }
      const results = raw.map((item: Record<string, unknown>) => {
        const address = item.address && typeof item.address === "object" ? item.address as Record<string, unknown> : {};
        return {
          name: addressLabel(item).slice(0, 200),
          details: String(item.display_name || "").slice(0, 280),
          lat: Number(item.lat),
          lng: Number(item.lon),
          type: String(item.type || "place").slice(0, 40),
          precision: address.house_number ? "exact" : address.road ? "street" : "place",
        };
      }).filter((item: { lat: number; lng: number }) => insideCoverage(item.lat, item.lng));
      const payload = { results };
      await serviceClient.rpc("yavoi_map_cache_put", { key_value: key, payload_value: payload, ttl_seconds: 604800 });
      return json(payload, 200, origin);
    }
    if (type === "reverse") {
      const lat = Number(body?.lat);
      const lng = Number(body?.lng);
      if (!Number.isFinite(lat) || !Number.isFinite(lng) || !insideCoverage(lat, lng)) return json({ error: "Punto fuera de cobertura." }, 400, origin);
      key = `reverse:v1:${lat.toFixed(5)}:${lng.toFixed(5)}`;
      const { data: cached } = await serviceClient.rpc("yavoi_map_cache_get", { key_value: key });
      if (cached) return json(cached, 200, origin);
      const { data: permitted } = await serviceClient.rpc("yavoi_map_rate_limit", { target_user: authData.user.id });
      if (!permitted) return json({ error: "Espera un segundo antes de consultar otro punto." }, 429, origin);
      const params = new URLSearchParams({ format: "jsonv2", lat: String(lat), lon: String(lng), zoom: "18", addressdetails: "1" });
      const upstream = await fetch(`https://nominatim.openstreetmap.org/reverse?${params}`, { headers: nominatimHeaders() });
      if (!upstream.ok) throw new Error("El buscador de direcciones no respondió.");
      const raw = await upstream.json();
      const payload = { name: addressLabel(raw).slice(0, 200), details: String(raw.display_name || "").slice(0, 280), lat, lng };
      await serviceClient.rpc("yavoi_map_cache_put", { key_value: key, payload_value: payload, ttl_seconds: 604800 });
      return json(payload, 200, origin);
    }
    if (type === "route") {
      const originPoint = body.origin || {};
      const destination = body.destination || {};
      const values = [Number(originPoint.lat), Number(originPoint.lng), Number(destination.lat), Number(destination.lng)];
      if (!values.every(Number.isFinite) || !insideCoverage(values[0], values[1]) || !insideCoverage(values[2], values[3])) return json({ error: "Ruta fuera de cobertura." }, 400, origin);
      key = `route:v2:${values.map((value) => value.toFixed(5)).join(":")}`;
      const { data: cached } = await serviceClient.rpc("yavoi_map_cache_get", { key_value: key });
      if (cached) return json(cached, 200, origin);
      const routeBase = Deno.env.get("ROUTING_BASE_URL") || "https://router.project-osrm.org";
      const upstream = await fetch(`${routeBase}/route/v1/driving/${values[1]},${values[0]};${values[3]},${values[2]}?overview=full&geometries=geojson&steps=true&alternatives=true`);
      if (!upstream.ok) throw new Error("El servicio de rutas no respondió.");
      const raw = await upstream.json();
      const candidates = Array.isArray(raw.routes) ? raw.routes.filter((item: Record<string, unknown>) => item?.geometry && Number(item?.distance) > 0 && Number(item?.duration) > 0) : [];
      if (!candidates.length) return json({ error: "No encontramos una ruta vial para esos puntos." }, 404, origin);
      const fastest = Math.min(...candidates.map((item: Record<string, unknown>) => Number(item.duration)));
      const shortest = Math.min(...candidates.map((item: Record<string, unknown>) => Number(item.distance)));
      // OSRM already avoids impossible streets. Rank valid alternatives by both time and distance,
      // with time slightly favored so the recommended route is useful while the trip is active.
      const route = candidates
        .map((item: Record<string, unknown>, index: number) => ({
          item,
          index,
          score: 0.65 * (Number(item.duration) / fastest) + 0.35 * (Number(item.distance) / shortest),
        }))
        .sort((a, b) => a.score - b.score || Number(a.item.duration) - Number(b.item.duration) || Number(a.item.distance) - Number(b.item.distance))[0].item;
      if (!route?.geometry?.coordinates) return json({ error: "No encontramos una ruta vial para esos puntos." }, 404, origin);
      const instructions = (route.legs || []).flatMap((leg: Record<string, unknown>) => Array.isArray(leg.steps) ? leg.steps : []).slice(0, 120).map((step: Record<string, unknown>) => {
        const maneuver = step.maneuver && typeof step.maneuver === "object" ? step.maneuver as Record<string, unknown> : {};
        return {
          type: String(maneuver.type || "continue").slice(0, 40),
          modifier: String(maneuver.modifier || "straight").slice(0, 30),
          street: String(step.name || "").slice(0, 160),
          distance_m: Math.max(0, Math.round(Number(step.distance) || 0)),
          duration_seconds: Math.max(0, Math.round(Number(step.duration) || 0)),
        };
      });
      const payload = { distance_km: Math.round(Number(route.distance) / 10) / 100, duration_minutes: Math.max(1, Math.ceil(Number(route.duration) / 60)), coordinates: route.geometry.coordinates.slice(0, 4000), instructions, route_quality: "time_distance_balanced" };
      await serviceClient.rpc("yavoi_map_cache_put", { key_value: key, payload_value: payload, ttl_seconds: 86400 });
      return json(payload, 200, origin);
    }
    return json({ error: "Operación de mapa no disponible." }, 400, origin);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "No se pudo consultar el mapa." }, 502, origin);
  }
});
