import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { errorMessage, isWeakPasswordError } from "../src/domain.js";

const root = new URL("../", import.meta.url);
const read = (path) => readFile(new URL(path, root)).then(String);

test("weak or leaked passwords are recognised in both Supabase error shapes", () => {
  // Formato nuevo: código y razones estructuradas.
  assert.equal(
    isWeakPasswordError({
      code: "weak_password",
      message: "Password is known to be weak and easy to guess.",
      weak_password: { reasons: ["pwned"] },
    }),
    true,
  );
  assert.equal(isWeakPasswordError({ code: "weak_password", weak_password: { reasons: ["length"] } }), true);
  // Formato antiguo: sólo el mensaje.
  assert.equal(isWeakPasswordError({ message: "Password is known to be weak and easy to guess, please pick a different one." }), true);
  // Nada que ver con contraseñas: no debe confundirse.
  assert.equal(isWeakPasswordError({ message: "Invalid login credentials" }), false);
  assert.equal(isWeakPasswordError(null), false);
});

test("the weak password message is explained in Spanish and asks for a stronger one", () => {
  const message = errorMessage({ code: "weak_password", message: "Password is known to be weak and easy to guess." });
  assert.match(message, /contraseña más larga/i);
  assert.match(message, /12 caracteres/);
  assert.doesNotMatch(message, /weak and easy to guess/);
});

test("sign in never dead-ends on a weak password: it opens the way to choose a new one", async () => {
  const portal = await read("src/portal.js");

  // El portal usa la regla del dominio, no una copia paralela.
  assert.match(portal, /import \{[\s\S]*?isWeakPasswordError,[\s\S]*?\} from "\.\/domain\.js";/);

  // Al rechazar el ingreso por contraseña débil, se lleva al formulario de recuperación
  // (que ya exige 12 caracteres) y se conserva el correo escrito.
  assert.match(portal, /if \(isWeakPasswordError\(error\)\) \{\n\s+authPage\(\n\s+"forgot",/);
  assert.match(portal, /\$\("#auth-form input\[name=email\]"\)/);
  assert.match(portal, /correo\.value = v\.email\.trim\(\)/);

  // El formulario de recuperación sigue pidiendo el mínimo que exige el servidor.
  assert.match(portal, /minlength="\$\{signup \|\| recovery \? 12 : 1\}"/);
});
