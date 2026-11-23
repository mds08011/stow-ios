# Plan

What this app is for, what exists, and the order the rest gets built in. Written 2026-11-23, when the repo was scaffolded.

## Principles

The same five as [Android Stow's roadmap](https://github.com/mds08011/stow/blob/main/docs/roadmap.md): low friction, Groq's free tier only, light-touch polish, field-first, and simple enough to maintain. Two more apply here:

1. **Build only what the web app cannot do.** Stow Web already works on iOS. This app earns its place with locked-screen recording, background upload and system entry points. Anything else waits until it is missed.
2. **No Mac.** Every change is compiled by GitHub Actions and tested on the phone through TestFlight. A round trip takes 15 to 30 minutes, so changes are small and the plain logic lives in `StowCore`, where it can be tested without a device.

## Why a separate repository

1. It needs a macOS runner. Android's build check runs on Linux in a few minutes. Sharing a repo would run both on every push or need path filters to keep them apart.
2. It releases on its own clock. TestFlight builds expire after 90 days and get rebuilt on a schedule that has nothing to do with Android releases.
3. It matches what already exists. Stow Web is its own repo, and the drift check in stow-web already compares across repos by cloning.
4. It has to be public for the macOS runners to be free, and a new repo starts with nothing in its history.

## Built in the scaffold

1. Record to 16 kHz mono AAC at 32 kbps, the same capture as Android. The `audio` background mode keeps it running with the screen locked.
2. Pause and resume, and an automatic pause when a phone call takes the microphone.
3. The microphone line shows the input iOS actually routed to.
4. Each recording becomes a history entry the moment it stops, before any upload. Any number can wait.
5. Upload through a background `URLSession`. iOS continues it after the phone is locked, waits for signal, and relaunches the app with the answer.
6. A **Transcription ready** notification when the text lands off screen.
7. Quality warnings from `verbose_json`, with Android's thresholds.
8. Copy and Share on the result. History with search and swipe to delete. **Send again** on a failed note.
9. The Groq key in the Keychain. The jargon dictionary as the Whisper prompt.
10. The daily usage line, worded as on Android.

Item 4 and unsent audio in Application Support are the two patchy-data lessons from the 2026-11 Android review, built in from the start.

## Next, in order

1. **First compile.** Done 2026-11-23. The first push built clean on Xcode 16.4, with one warning: `requestRecordPermission` on `AVAudioSession` is deprecated in iOS 17 in favour of the same call on `AVAudioApplication`. Swap it in the next change that touches `Recorder.swift`.
2. **Signing and TestFlight.** After the steps in [signing.md](signing.md), add a release workflow that archives, signs with the App Store Connect API key and uploads.
3. **First device test.** The list is below.
4. **Polish.** Port `TranscriptionPolisher` and `PolishPresets` into `StowCore`, with the prompts generated from the Kotlin source and added to the drift check. Presets, auto-polish and the raw or polished toggle follow.
5. **Start without opening the app.** An App Intent for the Action Button and Shortcuts, then a Lock Screen and Control Center control. iOS only lets a recording start in the background through an intent that also starts a Live Activity, so the Live Activity with a Stop button comes with this step.
6. **Survive a crash mid-recording.** An `.m4a` is only playable once it is closed, so a crash at minute 50 loses the note. Record in short segments, or to a format that is valid at any length, and join the parts before upload. Android has the same gap.
7. **Recordings over 25 MB.** About 1 hour 45 minutes at this bitrate. Split before upload and join the text.
8. **A scheduled rebuild** every 60 days, so the TestFlight build never expires in the field.

## Device tests owed

None of this can be checked in CI.

1. Record a note with the phone at arm's reach. The mic line reads `Phone mic` and the text is good.
2. Lock the screen while recording, wait a minute, unlock. The timer has kept counting and the audio covers the whole minute.
3. Stop, lock the phone at once, and wait. The **Transcription ready** notification arrives.
4. Record in airplane mode, stop, record a second note, then turn the radio back on. Both notes arrive without opening the app.
5. Take a phone call while recording. The recording pauses and picks up again.
6. Record with AirPods connected. The mic line still reads `Phone mic`.
7. Swipe Stow away during an upload, then reopen it. The note shows as failed with **Send again**, and sending works.
8. Record for 30 minutes or more. The upload completes.

## Deliberately left out

1. **Bluetooth microphone.** The phone's microphone records, as on Android, for the reasons in Android's roadmap: headset audio over the phone-call profile is processed for calls and likely transcribes worse. Reopen with the same condition, a real hands-free need, and behind a setting.
2. **Sync, accounts, iCloud.** Share covers it.
3. **The App Store.** TestFlight internal testing is the install path.
4. **A Mac-only workflow.** If a Mac appears, `xcodegen generate` gives a normal Xcode project, and CI stays the check of record.
