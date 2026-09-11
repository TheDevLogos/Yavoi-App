const GOOGLE_CLIENT_ID = /^[0-9]{6,}-[a-z0-9_-]{10,}\.apps\.googleusercontent\.com$/i;
let googleIdentityPromise = null;

export function validGoogleClientId(value) {
  const clientId = String(value || "").trim();
  return clientId.length <= 300 && GOOGLE_CLIENT_ID.test(clientId);
}

export async function createGoogleNonce() {
  const bytes = globalThis.crypto.getRandomValues(new Uint8Array(32));
  const raw = Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
  const digest = await globalThis.crypto.subtle.digest("SHA-256", new TextEncoder().encode(raw));
  const hashed = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return { raw, hashed };
}

export function loadGoogleIdentity() {
  if (globalThis.google?.accounts?.id) return Promise.resolve(globalThis.google);
  if (googleIdentityPromise) return googleIdentityPromise;
  if (!globalThis.document) return Promise.reject(new Error("Google Identity requiere un navegador."));

  googleIdentityPromise = new Promise((resolve, reject) => {
    const existing = document.querySelector("script[data-yavoi-google-identity]");
    const script = existing || document.createElement("script");
    const timeout = setTimeout(() => {
      googleIdentityPromise = null;
      reject(new Error("Google tardó demasiado en responder."));
    }, 10000);
    const ready = () => {
      clearTimeout(timeout);
      if (globalThis.google?.accounts?.id) resolve(globalThis.google);
      else {
        googleIdentityPromise = null;
        reject(new Error("No pudimos iniciar Google Identity."));
      }
    };
    const failed = () => {
      clearTimeout(timeout);
      googleIdentityPromise = null;
      reject(new Error("No pudimos cargar el acceso oficial de Google."));
    };
    script.addEventListener("load", ready, { once: true });
    script.addEventListener("error", failed, { once: true });
    if (!existing) {
      script.src = "https://accounts.google.com/gsi/client?hl=es";
      script.async = true;
      script.defer = true;
      script.referrerPolicy = "strict-origin-when-cross-origin";
      script.dataset.yavoiGoogleIdentity = "true";
      document.head.append(script);
    }
  });
  return googleIdentityPromise;
}
