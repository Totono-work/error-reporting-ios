# Totono Error Reporting for iOS

Add `https://github.com/Totono-work/error-reporting-ios.git` as a Swift package and initialize one `ErrorReporter` on the main actor at app startup. Keep the instance for the lifetime of the app.

```swift
import TotonoErrorReporting

let reporter = try ErrorReporter(origin: URL(string: "https://totono.work")!, key: ingestionKey)
reporter.addBreadcrumb(category: "checkout", message: "Opened checkout")
reporter.capture(error)
```

Handled events are queued locally. KSCrash writes native reports to disk and the SDK converts them on next launch. Test fatal crash delivery on a physical device outside the debugger. The SDK submits selected frames and binary metadata instead of the raw KSCrash file. Do not install another process crash handler alongside KSCrash.
