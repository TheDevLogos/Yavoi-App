# Activar acceso con Google, Microsoft y Apple

La interfaz y el flujo de retorno ya están integrados. La aplicación consulta el estado público de Supabase y habilita automáticamente cada botón cuando su proveedor queda activo; mientras tanto lo muestra como pendiente para evitar enviar al usuario a una pantalla de error. Para autenticar usuarios reales, Yavoi! necesita credenciales creadas por el propietario de la empresa en Google Cloud, Microsoft Entra y Apple Developer. Los secretos sólo se registran en Supabase; nunca deben copiarse al repositorio ni al navegador.

## Direcciones autorizadas

- Retorno que debe registrarse en cada proveedor: https://asjlyureqokifjkpdwgc.supabase.co/auth/v1/callback
- Sitio principal de Supabase Auth: https://yavoi-app.vercel.app
- Retorno permitido de la aplicación: https://yavoi-app.vercel.app/portal.html
- Para desarrollo local, agregar temporalmente http://localhost:5173/portal.html a las direcciones permitidas de Supabase.

## Google

1. Crear un cliente OAuth web en Google Cloud y configurar la pantalla de consentimiento con el nombre e identidad visual de Yavoi!.
2. Agregar el retorno de Supabase indicado arriba como URI de redirección autorizada.
3. En Supabase, abrir **Authentication > Sign In / Providers > Google**, habilitarlo y guardar el Client ID y Client Secret.
4. Publicar primero en modo de prueba con correos autorizados; después completar la verificación de Google antes de abrirlo a todo público.

## Microsoft / Hotmail

1. Registrar una aplicación web en Microsoft Entra para cuentas organizacionales y cuentas personales de Microsoft.
2. Agregar el retorno de Supabase como URI web de redirección.
3. Crear un secreto de cliente con vencimiento administrado y guardarlo en un gestor seguro.
4. En Supabase, habilitar **Azure (Microsoft)** e ingresar Client ID, Client Secret y el tenant compatible con cuentas personales.
5. El portal solicita el alcance email. Antes de producción, validar también el indicador de correo verificado que entrega Microsoft para impedir que un correo no confirmado se use como identidad confiable.

## Apple

1. En Apple Developer, crear o reutilizar un App ID, un Services ID para la web y una clave de Sign in with Apple.
2. Registrar el dominio de Yavoi! y el retorno de Supabase.
3. En Supabase, habilitar **Apple** y registrar Services ID, Team ID, Key ID y la clave privada.
4. Guardar el nombre y correo devueltos en el primer acceso, porque Apple puede no volver a proporcionarlos después.
5. Programar la rotación del secreto de Apple antes de su vencimiento.

## Prueba de aceptación

Para cada proveedor, usar una cuenta de prueba nueva y confirmar este recorrido:

1. El botón abre exclusivamente el dominio oficial del proveedor.
2. El consentimiento regresa a /portal.html sin exponer tokens en el contenido de la página.
3. La primera sesión muestra la elección Pasajero o Conductor; nunca ofrece Operaciones.
4. Al elegir Conductor se crea el expediente sin autorización y con avance inicial.
5. Al cerrar y volver a entrar, Supabase restaura la misma cuenta y el mismo rol.
6. Cancelar el consentimiento o usar un correo no válido muestra un error legible sin dejar una sesión parcial.
7. Operaciones continúa reservado a admin.yavoi@gmail.com y exige autenticación en dos pasos.

Si el correo administrativo cambia en el futuro, debe cambiarse mediante una migración controlada. El rol de Operaciones nunca se asigna desde un proveedor social.
