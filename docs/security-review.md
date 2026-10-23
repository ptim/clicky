# Security Review

Reviewed: 2026-10-23, at commit `a80fa80`.

Scope: a read-through of the Swift app, the Cloudflare Worker, build settings, entitlements, the release script, the dependency pins and the git history. I didn't build or run the app, and I didn't audit the third-party libraries themselves.

## Summary

I found no malware: no hidden downloads, no code being run behind the user's back, and no keylogging. But a stock build sends user data to the original author's services. And the Cloudflare Worker (the small proxy server that holds the API keys) has no authentication. Fix both before running it.

## Fix before installing

### 1. Speech and Claude's replies go to the author's PostHog account

`leanring-buddy/ClickyAnalytics.swift:18` hard-codes the original author's PostHog key (PostHog is an analytics service). On every interaction the app sends:

- what the user said (`trackUserMessageSent`, called at `CompanionManager.swift:523`)
- Claude's full reply (`trackAIResponseReceived`, called at `CompanionManager.swift:698`)

Because Claude is describing the user's screen, those replies can contain whatever was visible. The app also sends launch, permission and error events.

**Fix:** delete the `ClickyAnalytics.configure()` call in `leanring_buddyApp.swift`, or make `ClickyAnalytics` do nothing.

### 2. Onboarding sends the user's email to the author

If the user enters an email during onboarding, `CompanionManager.swift:152-172` posts it to the author's FormSpark form (`https://submit-form.com/RWbGJxmIs`, an online form service). It also links the email to the user in the author's PostHog.

**Fix:** skip that field, or remove `submitEmail`.

### 3. Anyone with the Worker URL can spend your API credit

`worker/src/index.ts` checks nothing: no shared secret, no allowed-origin check, no rate limit.

- `/chat` passes any request body straight to Anthropic with your key, so a caller can pick any model and any `max_tokens`.
- `/tts` and `/transcribe-token` work the same way for ElevenLabs and AssemblyAI.
- Your `*.workers.dev` URL is compiled into the app, and those URLs are easy to find.

**Fix:**

- Add a long random shared-secret header that the app sends and the worker checks.
- Have the worker set `model` and cap `max_tokens` itself, ignoring what the request asks for.
- At minimum, set spend limits on the Anthropic, ElevenLabs and AssemblyAI accounts.
- If you only run it locally, use `wrangler dev` without deploying. That avoids the exposure entirely.

## Worth knowing

- **It starts at login without asking.** `leanring_buddyApp.swift:61` registers it as a login item. You can turn this off in System Settings → Login Items, or remove the call.
- **It asks for more than it needs.**
  - The app sandbox is off (`ENABLE_APP_SANDBOX = NO`).
  - `leanring-buddy.entitlements` requests the camera, which nothing in the code uses. Remove `com.apple.security.device.camera`.
  - It also needs Screen Recording, Accessibility and the microphone, which is expected for what it does.
- **The keyboard listener is fine.** `GlobalPushToTalkShortcutMonitor.swift` is a listen-only tap. It sees every key press but only checks for the ctrl+option shortcut and doesn't store or send anything.
- **Screenshots only go to Claude, via your Worker.** They're taken only while the hotkey is held, and they're not saved to disk. Conversation history stays in memory, up to 10 turns.
- **Auto-update is off, and should stay off.** `Info.plist` still points Sparkle (the auto-update library) at `julianjear/makesomething-mac-app`, but `startSparkleUpdater()` is commented out. If it were turned back on, a third party could push signed updates to your machine. Removing `SUFeedURL` is safest.
- **Starting the onboarding video opens a third-party stream.** It plays a video from `stream.mux.com`, which can see your IP address.
- **An old Anthropic key is in the git history.** It's in the history of `project.pbxproj` and was removed in `d86c32f`. It's the author's key, not yours, so it doesn't affect you. Just never commit your own keys into this repo.
- **Some files call APIs directly but are never used.** `ElementLocationDetector.swift`, `OpenAIAPI.swift` and `OpenAIAudioTranscriptionProvider.swift` would send keys from the app itself. Nothing creates them unless `VoiceTranscriptionProvider` in `Info.plist` is changed, so leave it set to `assemblyai`.
- **Third-party libraries are pinned to versions from the projects' official repos.**
  - Sparkle 2.9.0, PostHog 3.47.0 and plcrashreporter 1.12.2 all come from their official GitHub repos.
  - The worker's only dependency is `wrangler`, a build tool.
- **The agent instruction files are safe.** I checked `CLAUDE.md` / `AGENTS.md` for instructions aimed at hijacking a coding assistant and found none.

## Recommended changes

Status as of branch `feature/enhance-local-security`:

1. ✅ Remove PostHog analytics: the SDK, `ClickyAnalytics.swift` and every call site are gone.
2. ✅ Remove the FormSpark email submission: the onboarding email form is gone too.
3. ✅ Add shared-secret auth to the worker, and have it set the model and a `max_tokens` cap. The worker requires `X-Clicky-Proxy-Secret`, fails closed when the secret is unset, allows only `claude-sonnet-4-6` / `claude-opus-4-6`, and clamps `max_tokens` to 1024. The app reads the secret from the gitignored `Config/Secrets.xcconfig`.
4. ⬜ Set spend limits on all three provider accounts. This is done in each provider's dashboard, not in code.
5. ✅ Remove the camera entitlement.
6. ✅ Make login-item registration opt-in: there is now a "Launch at login" toggle in the panel, off by default.
7. ✅ Remove `SUFeedURL` and `SUPublicEDKey` from `Info.plist`.
