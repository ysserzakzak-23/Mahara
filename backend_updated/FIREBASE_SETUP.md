# Firebase setup — what's wired vs. what you need to supply

Push notifications are the only feature that needs this. Everything else — including
the in-app notification list, which is stored in the database — works without it.

## Already wired in the code
- `backend/app/utils/fcm_client.py` — sends real pushes as soon as it is enabled; no code change needed.
- `service_hub/android/settings.gradle.kts` + `app/build.gradle.kts` — Google Services Gradle plugin.
- The Flutter side registers the device's FCM token with the backend automatically after login / on app startup (`lib/core/push/push_notification_service.dart`).

## What you have to supply yourself
These two are **deliberately not in this repository** — the first holds a private key,
and the second identifies someone else's Firebase project:

| File | Where to get it |
|---|---|
| `backend/firebase-service-account.json` | Firebase Console → Project settings → Service accounts → Generate new private key |
| `service_hub/android/app/google-services.json` | Firebase Console → Project settings → Your apps → Android app. A `.example` with the right shape sits beside it |

Then open `backend/.env` (your real one, not `.env.example`) and set:
```
FIREBASE_CREDENTIALS_PATH=./firebase-service-account.json
FCM_ENABLED=true
```
`FCM_ENABLED` ships as `false` so the server runs correctly without the key file.
Restart the backend after changing it.

Note that with `FCM_ENABLED=true` and no reachable Firebase, every notification still
succeeds — the push is attempted, fails, and is logged — but the attempt is made inside
the request, so booking and accepting an appointment get slower by the time the network
call takes to give up.

## How to test it worked
1. Make sure `firebase-service-account.json` is in the same folder you run `uvicorn` from (normally `backend/`).
2. Run the Flutter app on a **real Android device or an emulator with Google Play Services**
   (plain AVDs without Play Services can't get an FCM token).
3. Log in — the app silently registers your device's token.
4. Trigger any notification (e.g. book an appointment) and check the backend terminal —
   if `FCM_ENABLED=true` and the credentials are valid, you won't see the
   "FCM disabled" log line anymore, and a real push should arrive on the device.

## Not done yet (only iOS/Web, if you need them)
Only Android is configured (that's the only config file you sent). If you want push
notifications on iOS or Flutter Web too, either:
- Run `flutterfire configure` yourself (regenerates `lib/firebase_options.dart` for every platform), or
- Add an iOS/Web app in the Firebase console and send me `GoogleService-Info.plist` (iOS) or the Web config object.
