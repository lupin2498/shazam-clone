package vn.timnhac.app

import android.accounts.Account
import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import com.google.android.gms.auth.api.identity.AuthorizationRequest
import com.google.android.gms.auth.api.identity.AuthorizationResult
import com.google.android.gms.auth.api.identity.ClearTokenRequest
import com.google.android.gms.auth.api.identity.Identity
import com.google.android.gms.auth.api.identity.RevokeAccessRequest
import com.google.android.gms.common.api.ApiException
import com.google.android.gms.common.api.CommonStatusCodes
import com.google.android.gms.common.api.Scope
import com.google.android.gms.tasks.Task
import com.google.android.gms.tasks.Tasks
import io.flutter.plugin.common.MethodChannel

/**
 * Google account for "Đồng bộ Google Drive", with Google Identity Services authorization.
 *
 * Only two scopes: the e-mail address (shown in the settings) and the app's own hidden folder
 * on Drive (`drive.appdata`): the app cannot see any other file. No client id is compiled in:
 * Google matches the app by package name and signing certificate (SHA-1) against an Android
 * OAuth client in the Google Cloud project, see README.
 */
class GoogleAuth(private val activity: Activity) {
    private var pending: MethodChannel.Result? = null

    private val client get() = Identity.getAuthorizationClient(activity)

    /**
     * Answers {accessToken, email} or null when the user cancelled, or when [interactive] is false
     * and Google needs to show something (account choice, consent).
     */
    fun authorize(interactive: Boolean, email: String?, invalidToken: String?, result: MethodChannel.Result) {
        val request = AuthorizationRequest.builder().setRequestedScopes(SCOPES).apply {
            if (!email.isNullOrEmpty()) setAccount(Account(email, ACCOUNT_TYPE))
            else if (interactive) setPrompt(AuthorizationRequest.Prompt.SELECT_ACCOUNT)
        }.build()
        // A token the Drive API rejected must not come back from the cache.
        val cleared: Task<Void> = if (invalidToken.isNullOrEmpty()) {
            Tasks.forResult(null)
        } else {
            client.clearToken(ClearTokenRequest.builder().setToken(invalidToken).build())
        }
        cleared.continueWithTask { client.authorize(request) }
            .addOnSuccessListener { auth ->
                if (!auth.hasResolution()) return@addOnSuccessListener result.success(payload(auth))
                val intent = auth.pendingIntent
                if (!interactive || intent == null) return@addOnSuccessListener result.success(null)
                pending?.success(null)
                pending = result
                try {
                    activity.startIntentSenderForResult(intent.intentSender, REQ_AUTHORIZE, null, 0, 0, 0)
                } catch (e: IntentSender.SendIntentException) {
                    pending = null
                    result.error("google_error", e.message, null)
                }
            }
            .addOnFailureListener { e -> result.error(errorCode(e), e.message, null) }
    }

    /** Called from MainActivity.onActivityResult; true when the request was ours. */
    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQ_AUTHORIZE) return false
        val result = pending ?: return true
        pending = null
        if (resultCode != Activity.RESULT_OK) {
            result.success(null)
            return true
        }
        try {
            result.success(payload(client.getAuthorizationResultFromIntent(data)))
        } catch (e: ApiException) {
            result.error(errorCode(e), e.message, null)
        }
        return true
    }

    /** Forgets the cached token and revokes the app's access for this account. */
    fun signOut(email: String?, token: String?, result: MethodChannel.Result) {
        val tasks = mutableListOf<Task<*>>()
        if (!token.isNullOrEmpty()) tasks += client.clearToken(ClearTokenRequest.builder().setToken(token).build())
        if (!email.isNullOrEmpty()) {
            tasks += client.revokeAccess(
                RevokeAccessRequest.builder().setAccount(Account(email, ACCOUNT_TYPE)).setScopes(SCOPES).build()
            )
        }
        // Signing out locally must work offline too: failures are not reported.
        Tasks.whenAllComplete(tasks).addOnCompleteListener { result.success(null) }
    }

    private fun payload(auth: AuthorizationResult): Map<String, Any?> = mapOf(
        "accessToken" to auth.accessToken,
        "email" to runCatching { auth.toGoogleSignInAccount()?.email }.getOrNull(),
    )

    private fun errorCode(e: Exception): String = when ((e as? ApiException)?.statusCode) {
        // Package name or signing certificate not registered in the Google Cloud project.
        CommonStatusCodes.DEVELOPER_ERROR -> "not_configured"
        CommonStatusCodes.NETWORK_ERROR -> "network"
        CommonStatusCodes.CANCELED -> "cancelled"
        else -> "google_error"
    }

    companion object {
        private const val REQ_AUTHORIZE = 4104
        private const val ACCOUNT_TYPE = "com.google"
        private val SCOPES = listOf(
            Scope("email"),
            Scope("https://www.googleapis.com/auth/drive.appdata"),
        )
    }
}
