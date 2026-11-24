# Apple Developer setup: signed, notarized Mactivity

Done 2026-09-27: releases are signed with Developer ID M48435UMZ2 and notarized. This is how that was set up, for a new Mac or a new certificate. It turns a build into a DMG that opens normally on any Mac. It's done from Terminal with `make apple-setup`, plus three short stops in the browser. After that, every release is `make release`.

`make apple-setup` is safe to run as often as you like. Each run checks what's already done, does the next step it can, and tells you what's left. Nothing secret goes in the repo: the private keys go in your login keychain, and the working files in `~/.config/mactivity-signing`.

## What you download, and from where

| What | Where from | How |
|---|---|---|
| Xcode (you have it) | Mac App Store | already installed |
| Developer Program membership | developer.apple.com/programs/enroll | browser, once |
| Your certificate (`developerID_application.cer`) | developer.apple.com → Certificates | browser; the script opens the page |
| Apple's Developer ID intermediate certificate | apple.com/certificateauthority | the script downloads it |
| An app-specific password | account.apple.com → Sign-In and Security | browser; the script opens the page |
| Sparkle's key tools | come with the project's Sparkle package | the script finds them |

## Step 1. Enroll (browser, once)

1. Go to **developer.apple.com/programs/enroll** and sign in with your Apple ID. Two-factor authentication must be on.
2. Choose how you enroll:
   - **Individual ($99/year).** Usually approved within a day. macOS shows your **name** as the developer.
   - **Organization ($99/year).** Shows a **company name**. It needs a legal entity and a free D-U-N-S number, which can take one to two weeks. Switching from individual later changes the team ID.
3. Wait for the "Welcome to the Apple Developer Program" email.

## Step 2. Make the certificate request (Terminal)

```bash
make apple-setup
```

The script:
1. makes a private key and a certificate signing request, `Mactivity.certSigningRequest`;
2. opens the Apple page where you upload the request;
3. shows the request file in Finder.

## Step 3. Upload the request, download the certificate (browser)

On the page that opened (developer.apple.com → Certificates → **+**):
1. Choose **Developer ID Application**, then **Continue**. Only the Account Holder (you) can pick it.
2. Profile Type: **G2 Sub-CA (Xcode 11.4.1 or later)**.
3. **Choose File**, pick `Mactivity.certSigningRequest` (Finder is showing it), then **Continue**.
4. **Download.** It saves `developerID_application.cer` to Downloads.

## Step 4. Import it, and save the notary login (Terminal)

```bash
make apple-setup
```

The script:
1. finds the certificate in Downloads (or use `CER=/path/to/file.cer make apple-setup`) and checks that it matches your key;
2. adds Apple's intermediate certificate;
3. asks you to choose a password for a backup file, `developer-id.p12`;
4. imports the certificate and key into your login keychain, then deletes the unencrypted key file;
5. reads your **team ID** from the certificate and saves it in `project.yml` for `make release`;
6. opens account.apple.com so you can make an **app-specific password**: Sign-In and Security → App-Specific Passwords → **+**, named `notarytool`;
7. asks for your Apple ID email, then (through `notarytool`) the app-specific password. It checks them with Apple and saves them in your keychain as the profile `mactivity`;
8. makes Sparkle's update-signing key in your keychain, puts its public half in `project.yml`, and exports a backup copy of the private key.

**Save in your password manager:**
- `~/.config/mactivity-signing/developer-id.p12`, with its password;
- the app-specific password;
- `~/.config/mactivity-signing/sparkle-private-key.txt`.

Then delete `sparkle-private-key.txt` from the folder. Lose the Developer ID key and you make a new certificate. Lose the Sparkle key and existing installs can't take updates from you.

A final run prints four ✓s and "Ready".

## Step 5. Build, check, publish (Terminal)

```bash
make release
```

This:
1. archives with hardened runtime, and signs everything with your Developer ID;
2. notarizes with Apple (1–10 minutes) and staples the app;
3. builds the drag-to-install DMG, then signs, notarizes and staples it;
4. prints the Sparkle signature for the appcast.

The first time, macOS asks for your login password so `codesign` can use the key; click **Always Allow**. It may also ask to let Terminal control Finder, for the DMG window.

Check it the way a stranger's Mac will:
```bash
spctl -a -vv -t install dist/Mactivity-*.dmg
```
You want `accepted` and `source=Notarized Developer ID`. Then publish with `make site`, which points `/download/latest` at the signed DMG.

If notarization is rejected, get the reason with:
```bash
xcrun notarytool log <submission-id> --keychain-profile mactivity
```

## Notes

- **Debug builds stay ad-hoc.** `make build` and `make run` don't change. The team ID lives in `MACTIVITY_RELEASE_TEAM`, which only `make release` reads. Widgets and the privileged helper need the signed build.
- **No App ID, provisioning profile, or App Store Connect record** is needed. Developer ID covers apps distributed outside the App Store.
- **Renewal:** $99 a year. If the membership lapses, apps you've already shipped keep working, but you can't sign new ones. The certificate itself lasts five years.
- **Another Mac:** to release from a second Mac, double-click `developer-id.p12` to import it, then run `make apple-setup` for the notary profile. For the Sparkle key, run Sparkle's `generate_keys --account mactivity -f sparkle-private-key.txt`.
- **Other apps:** the membership, the Developer ID certificate and the notarytool profile cover every app you make; each app just passes the same team. Update keys are per app: Mactivity's Sparkle key is under the keychain account `mactivity`, so another app gets its own with `generate_keys --account <app>`.
- **The certificate on this Mac** (team M48435UMZ2) comes from Apple's older signing authority and expires 2027-02-01. Builds signed before then keep working. To sign after that, make a G2 certificate (Steps 2–4). `make release` always uses the team's certificate that expires last, so having both is fine.
