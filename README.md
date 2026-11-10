# Totono Error Reporting for Swift

Add `https://github.com/Totono-work/error-reporting-ios.git` as a Swift package and initialize one `ErrorReporter` on the main actor at app startup. Keep the instance for the lifetime of the app.

```swift
import TotonoErrorReporting

let reporter = try ErrorReporter(origin: URL(string: "https://totono.work")!, key: ingestionKey)
reporter.addBreadcrumb(category: "checkout", message: "Opened checkout")
reporter.capture(error)
```

Handled errors and breadcrumbs are queued locally on iOS, macOS, and Linux. On iOS and macOS, KSCrash writes native reports to disk and the SDK converts them on next launch. Test fatal crash delivery on a physical device outside the debugger. The SDK submits selected frames and binary metadata instead of the raw KSCrash file. Do not install another process crash handler alongside KSCrash.


## Raspberry Pi and other Linux hosts

Use a supported Swift toolchain on 64-bit ARM Linux. Add the same Swift package and use `ErrorReporter` on the main actor. Pass the deployment version explicitly because Linux executables generally lack Apple bundle version metadata.

```swift
import Foundation
import TotonoErrorReporting

@MainActor
func reportFailedJob(_ error: Error, ingestionKey: String) async throws {
    let reporter = try ErrorReporter(
        origin: URL(string: "https://totono.work")!,
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
