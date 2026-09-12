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
      key = `search:${query.toLocaleLowerCase("es-MX")}`;
      const { data: cached } = await serviceClient.rpc("yavoi_map_cache_get", { key_value: key });
      if (cached) return json(cached, 200, origin);
      const { data: permitted } = await serviceClient.rpc("yavoi_map_rate_limit", { target_user: authData.user.id });
      if (!permitted) return json({ error: "Espera un segundo antes de buscar otra dirección." }, 429, origin);
      const params = new URLSearchParams({ format: "jsonv2", q: `${query}, Chihuahua, México`, countrycodes: "mx", viewbox: "-105.7,28.4,-105.2,28.0", bounded: "1", limit: "6", addressdetails: "1" });
      const upstream = await fetch(`https://nominatim.openstreetmap.org/search?${params}`, { headers: { "user-agent": "Yavoi/1.0 (admin.yavoi@gmail.com)", "accept-language": "es-MX,es;q=0.9" } });
      if (!upstream.ok) throw new Error("El buscador de direcciones no respondió.");
      const raw = await upstream.json();
      const results = raw.map((item: Record<string, unknown>) => ({
        name: String(item.display_name || "").slice(0, 240),
        lat: Number(item.lat),
        lng: Number(item.lon),
        type: String(item.type || "place").slice(0, 40),
      })).filter((item: { lat: number; lng: number }) => insideCoverage(item.lat, item.lng));
      const payload = { results };
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
      const route = raw.routes?.[0];
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
      const payload = { distance_km: Math.round(Number(route.distance) / 10) / 100, duration_minutes: Math.max(1, Math.ceil(Number(route.duration) / 60)), coordinates: route.geometry.coordinates.slice(0, 4000), instructions };
      await serviceClient.rpc("yavoi_map_cache_put", { key_value: key, payload_value: payload, ttl_seconds: 86400 });
      return json(payload, 200, origin);
    }
    return json({ error: "Operación de mapa no disponible." }, 400, origin);
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : "No se pudo consultar el mapa." }, 502, origin);
  }
});
