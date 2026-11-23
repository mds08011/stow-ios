# Signing and TestFlight

How a build gets from this repo to the phone, with no Mac. The steps marked **owner** need the repository owner's Apple ID and cannot be done by anyone else.

**No credential goes in this repository.** The App Store Connect API key is a file ending in `.p8`. It is stored as a GitHub Actions secret and in a password manager, and nowhere else. `.gitignore` refuses `.p8`, `.p12`, `.cer` and `.mobileprovision` files as a backstop.

## One-time setup (owner)

1. Enroll in the Apple Developer Program as an individual, at <https://developer.apple.com/programs/enroll/> or in the Apple Developer app on the iPhone. It costs $99 a year and the Apple ID needs two-factor authentication. Approval can take up to two days.
2. At <https://developer.apple.com/account>, under Certificates, IDs & Profiles, then Identifiers, register an App ID with the explicit bundle ID `io.github.mds08011.stow`. No capabilities need ticking.
3. At <https://appstoreconnect.apple.com>, under Apps, add a new app: platform iOS, the bundle ID from step 2, any SKU. The name must be unique across the whole App Store even for an app that is never released, so "Stow" alone will be taken. The name on the home screen stays "Stow" whatever is entered here.
4. In App Store Connect, under Users and Access, then Integrations, then App Store Connect API, generate a team key with the Admin role. Download the `.p8` file. Apple offers the download once. Note the Key ID and the Issuer ID shown on the same page.
5. Note the Team ID from <https://developer.apple.com/account>, under Membership details.
6. Add four secrets to this repository, under Settings, then Secrets and variables, then Actions: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8` (the whole contents of the `.p8` file) and `APPLE_TEAM_ID`. From a terminal, `gh secret set ASC_KEY_P8 < AuthKey_XXXX.p8` reads the file without the key appearing on screen.
7. Move the `.p8` file into a password manager and delete the downloaded copy.
8. Install the TestFlight app on the iPhone and the iPad, signed in with the same Apple ID.

## What happens after that

1. A release workflow archives the app on a macOS runner, signs it with a certificate Apple manages in the cloud, and uploads it to App Store Connect. The workflow is not written yet. It needs the secrets from step 6 to be tested, so it follows the setup.
2. Apple processes the build, usually within half an hour.
3. In App Store Connect, under TestFlight, an Internal Testing group with the owner in it receives every build. Internal testing has no beta review.
4. The build shows up in the TestFlight app on both devices. Install it there.

## Things to know

1. A TestFlight build stops opening 90 days after upload. The scheduled rebuild in the plan covers this. Until it exists, rebuild by hand before the date TestFlight shows.
2. The Admin role on the API key is what lets a runner create signing certificates. If a narrower role turns out to be enough, replace the key with a narrower one.
3. If the key is ever exposed, revoke it on the same App Store Connect page and generate a new one. Revoking takes effect at once.
4. The membership renews yearly. If it lapses, installed TestFlight builds stop working.
