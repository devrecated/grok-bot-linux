/*
 * Linux implementation of Cursor's private sand_notification_settings addon.
 *
 * The JavaScript wrapper (dist/deps/sand-notification-settings/index.js)
 * documents the contract:
 *
 *   notification_settings_async()
 *     -> Promise<{ platform, setting, alertSetting? } | null>
 *
 * "The calling app's OS notification permission (macOS, Windows); null
 * elsewhere or when unreadable." Linux has no per-app notification
 * permission the app can query, so this resolves null, which is what the
 * official Linux build reports too.
 */

#include <node_api.h>

static napi_value NotificationSettingsAsync(napi_env env,
                                            napi_callback_info info) {
  (void)info;
  napi_deferred deferred;
  napi_value promise;
  napi_value result;
  if (napi_create_promise(env, &deferred, &promise) != napi_ok) {
    return NULL;
  }
  napi_get_null(env, &result);
  napi_resolve_deferred(env, deferred, result);
  return promise;
}

static napi_value Init(napi_env env, napi_value exports) {
  napi_value fn;
  napi_create_function(env, "notification_settings_async", NAPI_AUTO_LENGTH,
                       NotificationSettingsAsync, NULL, &fn);
  napi_set_named_property(env, exports, "notification_settings_async", fn);
  return exports;
}

NAPI_MODULE(sand_notification_settings, Init)
