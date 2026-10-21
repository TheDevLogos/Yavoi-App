package mx.yavoi.conductor;

import android.app.Activity;
import android.content.MutableContextWrapper;

import androidx.core.content.ContextCompat;
import androidx.credentials.Credential;
import androidx.credentials.CredentialManager;
import androidx.credentials.CustomCredential;
import androidx.credentials.GetCredentialRequest;
import androidx.credentials.GetCredentialResponse;
import androidx.credentials.exceptions.GetCredentialCancellationException;
import androidx.credentials.exceptions.GetCredentialException;
import androidx.credentials.exceptions.NoCredentialException;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.google.android.libraries.identity.googleid.GetGoogleIdOption;
import com.google.android.libraries.identity.googleid.GetSignInWithGoogleOption;
import com.google.android.libraries.identity.googleid.GoogleIdTokenCredential;

@CapacitorPlugin(name = "YavoiGoogleAuth")
public class YavoiGoogleAuthPlugin extends Plugin {
    @PluginMethod
    public void signIn(PluginCall call) {
        String serverClientId = call.getString("serverClientId", "").trim();
        if (serverClientId.isEmpty()) {
            call.reject("Falta la configuración de acceso de Google.");
            return;
        }

        Activity activity = getActivity();
        if (activity == null || activity.isFinishing()) {
            call.reject("No se pudo abrir el acceso de Google. Vuelve a intentarlo.");
            return;
        }

        CredentialManager credentialManager = CredentialManager.create(activity);
        GetGoogleIdOption googleIdOption = new GetGoogleIdOption.Builder()
            .setFilterByAuthorizedAccounts(false)
            .setServerClientId(serverClientId)
            .setAutoSelectEnabled(false)
            .build();
        GetCredentialRequest request = new GetCredentialRequest.Builder()
            .addCredentialOption(googleIdOption)
            .build();

        requestCredential(credentialManager, activity, request, call, serverClientId, true);
    }

    private void requestCredential(
        CredentialManager credentialManager,
        Activity activity,
        GetCredentialRequest request,
        PluginCall call,
        String serverClientId,
        boolean allowGoogleButtonFallback
    ) {
        MutableContextWrapper activityContext = new MutableContextWrapper(activity);
        credentialManager.getCredentialAsync(
            activityContext,
            request,
            null,
            ContextCompat.getMainExecutor(activity),
            new androidx.credentials.CredentialManagerCallback<GetCredentialResponse, GetCredentialException>() {
                @Override
                public void onResult(GetCredentialResponse response) {
                    resolveGoogleIdToken(call, response.getCredential());
                }

                @Override
                public void onError(GetCredentialException error) {
                    if (allowGoogleButtonFallback && error instanceof NoCredentialException) {
                        requestGoogleButtonFlow(credentialManager, activity, call, serverClientId);
                        return;
                    }
                    rejectCredentialFailure(call, error);
                }
            }
        );
    }

    private void requestGoogleButtonFlow(
        CredentialManager credentialManager,
        Activity activity,
        PluginCall call,
        String serverClientId
    ) {
        GetSignInWithGoogleOption option = new GetSignInWithGoogleOption.Builder(serverClientId).build();
        GetCredentialRequest request = new GetCredentialRequest.Builder()
            .addCredentialOption(option)
            .build();
        requestCredential(credentialManager, activity, request, call, serverClientId, false);
    }

    private void resolveGoogleIdToken(PluginCall call, Credential credential) {
        if (!(credential instanceof CustomCredential)
            || !GoogleIdTokenCredential.TYPE_GOOGLE_ID_TOKEN_CREDENTIAL.equals(credential.getType())) {
            call.reject("Google no devolvió un token de acceso compatible. Vuelve a intentarlo.");
            return;
        }

        try {
            GoogleIdTokenCredential googleCredential = GoogleIdTokenCredential.createFrom(credential.getData());
            String token = googleCredential.getIdToken();
            if (token == null || token.isEmpty()) {
                call.reject("Google no entregó un identificador de acceso válido.");
                return;
            }
            JSObject response = new JSObject();
            response.put("idToken", token);
            call.resolve(response);
        } catch (Exception error) {
            call.reject("No pudimos completar el acceso con Google. Vuelve a intentarlo.", error);
        }
    }

    private void rejectCredentialFailure(PluginCall call, GetCredentialException error) {
        if (error instanceof GetCredentialCancellationException) {
            call.reject("Cancelaste la selección de cuenta. Puedes volver a elegir una cuenta de Google e intentarlo de nuevo.");
        } else if (error instanceof NoCredentialException) {
            call.reject("No encontramos una cuenta de Google disponible en este dispositivo. Agrega una cuenta en Android e inténtalo de nuevo.");
        } else {
            call.reject("Google no pudo completar el acceso. Revisa tu conexión y los Servicios de Google Play e inténtalo de nuevo.", error);
        }
    }
}
