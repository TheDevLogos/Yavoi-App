package mx.yavoi.conductor;

import android.app.Activity;
import android.content.Intent;

import androidx.activity.result.ActivityResult;

import com.getcapacitor.annotation.ActivityCallback;
import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.google.android.gms.auth.api.signin.GoogleSignIn;
import com.google.android.gms.auth.api.signin.GoogleSignInAccount;
import com.google.android.gms.auth.api.signin.GoogleSignInClient;
import com.google.android.gms.auth.api.signin.GoogleSignInOptions;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;

@CapacitorPlugin(name = "YavoiGoogleAuth")
public class YavoiGoogleAuthPlugin extends Plugin {
    @PluginMethod
    public void signIn(PluginCall call) {
        String serverClientId = call.getString("serverClientId", "").trim();
        if (serverClientId.isEmpty()) {
            call.reject("Falta la configuración de acceso de Google.");
            return;
        }
        GoogleSignInOptions options = new GoogleSignInOptions.Builder(GoogleSignInOptions.DEFAULT_SIGN_IN)
            .requestIdToken(serverClientId)
            .requestEmail()
            .build();
        GoogleSignInClient client = GoogleSignIn.getClient(getContext(), options);
        startActivityForResult(call, client.getSignInIntent(), "handleGoogleSignIn");
    }

    @ActivityCallback
    private void handleGoogleSignIn(PluginCall call, ActivityResult result) {
        if (call == null) return;
        if (result.getResultCode() != Activity.RESULT_OK || result.getData() == null) {
            call.reject("El acceso con Google fue cancelado.");
            return;
        }
        try {
            Task<GoogleSignInAccount> task = GoogleSignIn.getSignedInAccountFromIntent(result.getData());
            GoogleSignInAccount account = task.getResult(ApiException.class);
            String token = account == null ? null : account.getIdToken();
            if (token == null || token.isEmpty()) {
                call.reject("Google no entregó un identificador de acceso válido.");
                return;
            }
            JSObject response = new JSObject();
            response.put("idToken", token);
            call.resolve(response);
        } catch (ApiException error) {
            call.reject("No pudimos completar el acceso con Google (" + error.getStatusCode() + ").", error);
        }
    }
}
