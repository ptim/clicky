# Release Scripts

## `release.sh` — Ship a new version of makesomething

Automates the full release pipeline: build → sign → DMG → notarize → Sparkle appcast → GitHub Release.

### Quick start

```bash
# Auto-bumps version and build number from the latest GitHub Release
./scripts/release.sh
```

The script checks GitHub for the latest release (e.g. `v1.5`, build 6) and automatically bumps to `v1.6`, build 7. You'll see a confirmation prompt before anything runs.

### Override version or build

```bash
# Set a specific marketing version (auto-bumps build)
./scripts/release.sh 2.0

# Set both marketing version and build number
./scripts/release.sh 2.0 10
```

### Safety

- **Duplicate detection**: If the tag already exists on GitHub, the script exits with an error and suggests what to do.
- **Confirmation prompt**: Shows the version, build, and previous release before proceeding. Press `y` to continue.

### What it does

1. Fetches the latest release from GitHub to determine version + build
2. Archives the app via `xcodebuild`
3. Exports a signed `.app` with Developer ID
4. Creates a DMG with the drag-to-Applications background
5. Notarizes the DMG with Apple (Gatekeeper compliance)
6. Signs the DMG with the Sparkle EdDSA key
7. Generates `appcast.xml` for Sparkle auto-updates
8. Creates a GitHub Release with the DMG attached
9. Pushes the updated `appcast.xml` to the releases repo

### One-time setup (prerequisites)

1. **Xcode** with your Developer ID signing certificate
2. **Homebrew tools**:
   ```bash
   brew install create-dmg gh
   ```
3. **GitHub CLI auth**:
   ```bash
   gh auth login
   ```
4. **Apple notarization credentials** (stored in Keychain):
   ```bash
   xcrun notarytool store-credentials "AC_PASSWORD" \
       --apple-id YOUR_APPLE_ID \
       --team-id YOUR_TEAM_ID
   ```
   You'll be prompted for an app-specific password (generate one at [appleid.apple.com](https://appleid.apple.com)).
5. **Sparkle EdDSA key** — already generated and stored in Keychain (done during initial Sparkle setup)
6. **Build the project in Xcode at least once** so SPM downloads Sparkle and the Sparkle CLI tools are available

## `build-clicky-launcher-app.sh` — Start the local worker with Clicky

For builds whose `CLICKY_WORKER_BASE_URL` points at `wrangler dev` (`http://localhost:8787`). Builds **Clicky Launcher.app**, which:

1. Starts `npx wrangler dev` in `worker/` (keys from `worker/.dev.vars`), unless something is already listening on port 8787
2. Opens Clicky once the worker is up
3. Stops the worker again when Clicky quits (only if the launcher started it)

```bash
# Installs to ~/Applications
./scripts/build-clicky-launcher-app.sh

# Or somewhere else
./scripts/build-clicky-launcher-app.sh /Applications
```

The app runs `scripts/start-clicky-with-local-worker.sh` from this checkout by absolute path, so rebuild it if you move the repository. You can also run that script directly. Logs go to `~/Library/Logs/Clicky/`. Add the launcher (not Clicky) to Login Items to start both at login.
