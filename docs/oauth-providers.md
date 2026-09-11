# Activar acceso con Google, Microsoft y Apple

La aplicación integra Google Identity Services con el botón oficial generado por Google. El navegador recibe una credencial de identidad, Supabase la valida y crea o recupera la sesión. Cada intento usa un nonce aleatorio: Google recibe su huella SHA-256 y Supabase recibe el valor original. El Client Secret nunca llega al navegador ni se guarda en el repositorio.

El correo `admin.yavoi@gmail.com` puede ser propietario del proyecto de Google Cloud y correo de soporte. No se necesita ni se debe compartir su contraseña. El rol de Operaciones se conserva por separado y nunca se obtiene por iniciar sesión con Google.

## Google: datos que faltan para activar producción

Se necesita crear en Google Cloud un cliente OAuth de tipo **Aplicación web**. Al terminar, Google entrega:

- **Client ID**, identificador público terminado en `.apps.googleusercontent.com`.
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
5. No agregar `TU_ID...`; copiar el Client ID real que entrega Google.
6. En Vercel, crear `VITE_GOOGLE_CLIENT_ID` para Production y Preview con ese Client ID público y volver a desplegar.
7. En Supabase, abrir **Authentication > Sign In / Providers > Google**, activar el proveedor y guardar el mismo Client ID junto con su Client Secret privado.
8. Dejar la aplicación de Google en prueba mientras se valida con las cuentas autorizadas; después publicarla para usuarios externos.

El flujo oficial implementado no necesita iniciar el acceso mediante una URI de redirección de Supabase: el botón entrega el token al código de Yavoi! y éste lo intercambia con `signInWithIdToken`. Si en el futuro se agrega también el flujo OAuth con redirección, su callback será `https://asjlyureqokifjkpdwgc.supabase.co/auth/v1/callback`.

## Supabase Auth

- Site URL: `https://yavoi-app.vercel.app`
- Redirect permitido para correo, recuperación y proveedores con redirección: `https://yavoi-app.vercel.app/portal.html`
- Desarrollo local temporal: `http://localhost:5173/portal.html`

La pantalla consulta el estado público de Supabase. Sólo muestra el botón oficial cuando el proveedor Google está activo y `VITE_GOOGLE_CLIENT_ID` contiene un identificador válido. Si falta cualquiera de los dos, el control queda bloqueado con un mensaje claro y el acceso por correo continúa funcionando.

## Microsoft / Hotmail

1. Registrar una aplicación web en Microsoft Entra para cuentas organizacionales y personales.
2. Agregar el callback de Supabase como URI web de redirección.
3. Crear un secreto de cliente con vencimiento administrado y guardarlo en un gestor seguro.
4. En Supabase, habilitar **Azure (Microsoft)** e ingresar Client ID, Client Secret y el tenant compatible con cuentas personales.
5. Antes de producción, validar el indicador de correo verificado entregado por Microsoft.

## Apple

1. En Apple Developer, crear o reutilizar un App ID, un Services ID para la web y una clave de Sign in with Apple.
2. Registrar el dominio de Yavoi! y el callback de Supabase.
3. En Supabase, habilitar **Apple** y registrar Services ID, Team ID, Key ID y la clave privada.
4. Guardar nombre y correo en el primer acceso, porque Apple puede no volver a proporcionarlos.
5. Programar la rotación del secreto de Apple antes de su vencimiento.

## Prueba de aceptación de Google

1. Abrir `/portal.html` y comprobar que Google dibuja su botón oficial en español.
2. Probar una cuenta nueva y una existente; ambas deben regresar al portal sin exponer el token en la dirección.
3. La primera sesión debe mostrar la elección Pasajero o Conductor; nunca debe ofrecer Operaciones.
4. Al elegir Conductor se crea el expediente sin autorización y con su avance inicial.
5. Cerrar y volver a entrar debe restaurar la misma cuenta y el mismo rol.
6. Cancelar el selector de Google o bloquear cookies debe dejar la pantalla utilizable y sin sesión parcial.
7. Revisar el modo móvil y confirmar que el botón no se corta ni rebasa el formulario.
8. Operaciones debe seguir reservado a `admin.yavoi@gmail.com` y exigir autenticación en dos pasos.
