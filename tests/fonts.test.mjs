import { test } from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root)).then(String);

test("app fonts are served from our own origin so the production CSP loads them", async () => {
  const [landing, portal, worker, config] = await Promise.all([
    read("styles.css"),
    read("src/portal.css"),
    read("public/sw.js"),
    read("vercel.json"),
  ]);

  // Ninguna hoja descarga ya tipografías de terceros: el CSP de producción bloqueaba esa petición.
  // (Se busca la URL real, no una mención en comentarios.)
  assert.doesNotMatch(landing, /https?:\/\/fonts\.(googleapis|gstatic)\.com/);
  assert.doesNotMatch(portal, /https?:\/\/fonts\.(googleapis|gstatic)\.com/);
  // Ninguna hoja importa ya CSS de un origen ajeno (lo propio de Vite queda como import relativo).
  assert.doesNotMatch(landing, /@import\s+(url\()?['"]?https?:\/\//);
  assert.doesNotMatch(portal, /@import\s+(url\()?['"]?https?:\/\//);

  // Fuentes variables locales, con el rango completo que usan los diseños.
  assert.match(
    landing,
    /@font-face\{font-family:'Nunito';font-style:normal;font-weight:500 1000;font-display:swap;src:url\('\/fonts\/nunito-latin\.woff2'\)/
  );
  assert.match(
    portal,
    /@font-face\{font-family:'Inter';font-style:normal;font-weight:100 900;font-display:swap;src:url\('\/fonts\/inter-latin\.woff2'\)/
  );

  // El portal declara la familia 'Inter', que antes nunca se cargaba (caía a Arial).
  assert.match(portal, /font-family:Inter,/);

  // Los archivos existen y quedan en la caché del shell para funcionar sin conexión.
  for (const file of ["nunito-latin", "inter-latin"]) {
    await access(new URL(`public/fonts/${file}.woff2`, root));
    assert.ok(worker.includes(`/fonts/${file}.woff2`), `${file}.woff2 debe estar en CORE del service worker`);
  }

  // El CSP no necesita relajarse: el origen propio ya estaba permitido.
  const headers = JSON.parse(config).headers[0].headers;
  const csp = headers.find((header) => header.key === "Content-Security-Policy")?.value || "";
  assert.match(csp, /font-src 'self'/);
  assert.doesNotMatch(csp, /fonts\.(googleapis|gstatic)\.com/);
});
