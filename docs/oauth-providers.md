# Activar acceso con Google

La aplicación integra Google Identity Services con el botón oficial generado por Google. El navegador recibe una credencial de identidad, Supabase la valida y crea o recupera la sesión. Cada intento usa un nonce aleatorio: Google recibe su huella SHA-256 y Supabase recibe el valor original. El Client Secret nunca llega al navegador ni se guarda en el repositorio. Por ahora no se muestran accesos de Microsoft ni Apple.

El correo `admin.yavoi@gmail.com` puede ser propietario del proyecto de Google Cloud y correo de soporte. No se necesita ni se debe compartir su contraseña. El rol de Operaciones se conserva por separado y nunca se obtiene por iniciar sesión con Google.

## Google: datos que faltan para activar producción

El cliente OAuth web ya tiene este identificador público, integrado en la compilación de Yavoi!:

`903354099441-4la2ivgqknn9q8kj1ghku6caebc1a4ar.apps.googleusercontent.com`

Para terminar la activación falta:

- **Client Secret**, credencial privada que debe escribirse directamente en Supabase y nunca enviarse por chat, incluirse en el código o guardarse en GitHub.

También se necesita definir en Google Auth Platform:

- Nombre de la aplicación: `Yavoi!`.
- Correo de soporte y contacto: `admin.yavoi@gmail.com` mientras se habilita el dominio oficial.
- Audiencia externa. Durante pruebas, agregar las cuentas Gmail que probarán el acceso.
- Página principal: `https://yavoi-app.vercel.app`.
- Aviso de privacidad y términos públicos antes de solicitar publicación general o verificación de marca.

## Configuración exacta de Google

1. Entrar a Google Cloud con `admin.yavoi@gmail.com`, crear o seleccionar el proyecto de Yavoi! y abrir **Google Auth Platform**.
2. Completar **Branding**, **Audience** y **Data Access**. Para el acceso básico bastan los alcances `openid`, `email` y `profile` que incluye Google Identity Services.
3. En **Clients**, crear un cliente **Web application**.
4. Agregar estos **Authorized JavaScript origins**, sin ruta ni diagonal final:
   - `https://yavoi-app.vercel.app`
   - `http://localhost:5173` para desarrollo local
5. Confirmar que el Client ID mostrado arriba pertenece a ese cliente web.
6. En Supabase, abrir **Authentication > Sign In / Providers > Google**, activar el proveedor y guardar ese Client ID junto con su Client Secret privado.
7. Dejar la aplicación de Google en prueba mientras se valida con las cuentas autorizadas; después publicarla para usuarios externos.

El flujo oficial implementado no necesita iniciar el acceso mediante una URI de redirección de Supabase: el botón entrega el token al código de Yavoi! y éste lo intercambia con `signInWithIdToken`. Si en el futuro se agrega también el flujo OAuth con redirección, su callback será `https://asjlyureqokifjkpdwgc.supabase.co/auth/v1/callback`.

## Supabase Auth

- Site URL: `https://yavoi-app.vercel.app`
- Redirect permitido para correo, recuperación y proveedores con redirección: `https://yavoi-app.vercel.app/portal.html`
- Desarrollo local temporal: `http://localhost:5173/portal.html`

La pantalla consulta el estado público de Supabase. Sólo muestra el botón oficial cuando el proveedor Google está activo y el Client ID integrado es válido. `VITE_GOOGLE_CLIENT_ID` queda disponible como reemplazo controlado si el cliente cambia en el futuro. Mientras Supabase reporte Google como inactivo, el control queda bloqueado con un mensaje claro y el acceso por correo continúa funcionando.

## Prueba de aceptación de Google

1. Abrir `/portal.html` y comprobar que Google dibuja su botón oficial en español.
2. Probar una cuenta nueva y una existente; ambas deben regresar al portal sin exponer el token en la dirección.
3. La primera sesión debe mostrar la elección Pasajero o Conductor; nunca debe ofrecer Operaciones.
4. Al elegir Conductor se crea el expediente sin autorización y con su avance inicial.
5. Cerrar y volver a entrar debe restaurar la misma cuenta y el mismo rol.
6. Cancelar el selector de Google o bloquear cookies debe dejar la pantalla utilizable y sin sesión parcial.
7. Revisar el modo móvil y confirmar que el botón no se corta ni rebasa el formulario.
8. Operaciones debe seguir reservado a `admin.yavoi@gmail.com` y exigir autenticación en dos pasos.
