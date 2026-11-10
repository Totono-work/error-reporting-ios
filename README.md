# Totono Error Reporting for Swift

Add `https://github.com/Totono-work/error-reporting-ios.git` as a Swift package and initialize one `ErrorReporter` on the main actor at app startup. Keep the instance for the lifetime of the app.

```swift
import TotonoErrorReporting

let reporter = try ErrorReporter(key: ingestionKey)
reporter.addBreadcrumb(category: "checkout", message: "Opened checkout")
reporter.capture(error)
```

The SDK sends reports to Totono automatically. The public, write-only project key can be embedded in your app. Handled errors and breadcrumbs are queued locally on iOS, macOS, and Linux. On iOS and macOS, KSCrash writes native reports to disk and the SDK converts them on next launch. Test fatal crash delivery on a physical device outside the debugger. The SDK submits selected frames and binary metadata instead of the raw KSCrash file. Do not install another process crash handler alongside KSCrash.

## Upload dSYMs for symbolication

Set Xcode's **Debug Information Format** to **DWARF with dSYM File** for release builds. Use the dSYMs from the `.xcarchive` for the build you distribute. Set `TOTONO_ERROR_ARTIFACT_KEY` to the project's artifact key as a secret in your release environment.

On a Mac with Node.js and npm, run the uploader from `@totono/error-reporting`. Give it the Mach-O file inside the `.dSYM` bundle and the UUID and architecture shown by `dwarfdump`.

```sh
DWARF_FILE="MyApp.xcarchive/dSYMs/MyApp.app.dSYM/Contents/Resources/DWARF/MyApp"
xcrun dwarfdump --uuid "$DWARF_FILE"

# Set UUID to the value shown for arm64 above.
npx --package @totono/error-reporting totono-error-artifact dsym "$DWARF_FILE" "$UUID" arm64
```

Repeat the upload for each app or framework binary you want to symbolicate and each architecture you distribute. Totono matches crash frames to debug files by binary UUID and architecture.

## Raspberry Pi and other Linux hosts

Use a supported Swift toolchain on 64-bit ARM Linux. Add the same Swift package and use `ErrorReporter` on the main actor. Pass the deployment version explicitly because Linux executables generally lack Apple bundle version metadata.

```swift
import Foundation
import TotonoErrorReporting

@MainActor
func reportFailedJob(_ error: Error, ingestionKey: String) async throws {
    let reporter = try ErrorReporter(
        key: ingestionKey,
        release: "sensor-daemon-1.0.0"
    )
    reporter.addBreadcrumb(category: "sensor", message: "Polling cycle failed")
    reporter.capture(error)
    await reporter.flush()
}
```

For a long-running service, keep one reporter instance and call `flush()` before a normal shutdown. The Linux queue lives under `$XDG_STATE_HOME/TotonoErrorReporting`, or under `~/.local/state/TotonoErrorReporting` by default. Give the service user write access to that state directory.

Linux events use the `linux` platform. Deploy a Totono collector that accepts that platform before enabling the Linux client. Linux supports handled Swift errors, breadcrumbs, a persistent queue, retries, and best-effort local stack frames. Automatic fatal crash capture and Mach-O/dSYM symbolication are Apple features.
