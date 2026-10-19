# Apple Watch

openGym on the wrist: the set that is next with its weight and reps, Done, the rest counting down
with a buzz at the end, and the session saved to Health with your heart rate. It works with the
iPhone in reach, and without it: a session started on the watch runs there on its own and is
handed to the phone the next time they are in reach.

This is a native SwiftUI app (`frontend/ios/App/OpenGymWatch`) embedded in the Capacitor iPhone
app. watchOS has no WebView, so none of the web UI runs on the watch, and it holds no training
logic either: everything it shows is worked out on the phone by the same code a session started
there uses.

## How it works

| | Phone → watch | Watch → phone |
|---|---|---|
| **The pack** | Every session the watch can start by itself (today's first, then each routine), already built with the progression engine's weights, laid out set by set with the rest after each (`lib/watch.js buildWatchPack`). Sent as a file whenever the plan or history changes. | |
| **A workout started on the phone** | Its sets and rest as a snapshot whenever either changes (`buildLiveSnapshot`). The watch shows it by itself. | Each set ticked, rest started or skipped, and Finish, as a command (`lib/watch-bridge.js handle`). |
| **A session started on the watch** | | The whole session at Finish: the entries it was started with plus every change, saved on the phone through the ordinary finish path (`prepareWatchSession`), so next weights and PRs are exactly as if it was logged on the phone. |

Commands go as a message while the phone is in reach and are always also queued
(`transferUserInfo`, or a file for a whole session), which watchOS delivers in order whenever the
two meet again. The phone keeps what arrives in an inbox file until the web app has applied it,
and counts each command id once.

- A watch session that arrives while a workout is running on the phone waits in the inbox until
  that one is finished.
- The Health workout (`HKWorkoutSession`) keeps the watch app running with the wrist down, so the
  rest timer buzzes on time; a notification on the watch is the fallback.
- On the iPhone, the end of a rest is now a local notification too (`lib/rest-alert.js`), which iOS
  also shows on the watch when the phone is locked.
- The watch's words come from the phone in its language (`watchLabels`); English where a
  translation is missing.

## Building it

Requirements: Xcode 26, a paid Apple Developer account (HealthKit), an Apple Watch on watchOS 26
paired with the iPhone.

1. `cd frontend && npm ci && npm run build:mobile` as for the iPhone app.
2. `npx cap open ios`. The project has two targets: **App** (the iPhone app, which embeds the
   watch app) and **OpenGymWatch**. Both are set to the fork's bundle ids
   (`com.sammul.opengym`, `com.sammul.opengym.watchkitapp`) and team.
3. On the **OpenGymWatch** target, Signing & Capabilities should show **HealthKit**; if Xcode asks
   to register the App ID or fix the profile, let it.
4. Run the **App** scheme on the iPhone. The watch app installs with it (on the watch:
   Watch app on iPhone → My Watch → openGym → Show App on Apple Watch, if it does not appear).
   To debug the watch side, pick the **OpenGymWatch** scheme and the watch as destination.

## Trying it

- Open openGym on the iPhone once: the routines appear on the watch.
- Start a workout on the phone: the watch switches to it. Tick a set on the watch and the phone
  shows it ticked, and both count the same rest.
- Put the phone in airplane mode, start today's session on the watch, log it, Finish. Turn airplane
  mode off and open openGym on the phone: the workout is in History with the next session's
  weights moved on.

## Not done yet

- Logging drop-set drops and rest-pause bursts on the watch: such sets are shown and ticked as
  their main set.
- A Smart Stack widget or complication.
- Starting a phone workout from the watch: a session started on the watch runs on the watch.
