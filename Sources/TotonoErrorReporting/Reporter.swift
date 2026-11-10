import Foundation
#if os(Linux)
import Crypto
import FoundationNetworking
#else
import CryptoKit
#endif
#if canImport(KSCrashRecording)
import KSCrashRecording
#endif

@MainActor
public final class ErrorReporter {
    public enum ConfigurationError: Error {
        case invalidEndpoint, invalidKey
    }

    private struct Entry: Codable {
        let id: UUID
        let date: Date
        let body: Data
    }

    private let endpoint: URL
    private let key: String
    private let release: String
    private let build: String
    private let environment: String
    private let file: URL
    private let session: URLSession
    private let shouldSend: ([String: Any]) -> Bool
    private var entries: [Entry] = []
    private var breadcrumbs: [[String: String]] = []
    private var attempt = 0
    private var retryAt = Date.distantPast
    private var task: Task<Void, Never>?
    private var sending = false

    public init(
        origin: URL,
        key: String,
        environment: String = "production",
        release: String? = nil,
        build: String? = nil,
        shouldSend: @escaping ([String: Any]) -> Bool = { _ in true }
    ) throws {
        guard origin.scheme == "https", origin.host != nil, origin.user == nil, origin.password == nil,
              let url = URL(string: "/api/public/error-reporting/v1/events", relativeTo: origin)?.absoluteURL else {
            throw ConfigurationError.invalidEndpoint
        }
        guard key.range(of: "^ttr_[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            throw ConfigurationError.invalidKey
        }
        endpoint = url
        self.key = key
        self.environment = Self.clean(environment, limit: 64)
        let releaseName = Self.clean(release ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "", limit: 100)
        self.release = releaseName.isEmpty ? "unknown" : releaseName
        self.build = Self.clean(build ?? (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "", limit: 100)
        let scope = SHA256.hash(data: Data((url.absoluteString + key).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let directory = try Self.queueDirectory(scope: scope)
        file = directory.appendingPathComponent("queue.json")
        self.shouldSend = shouldSend

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)

        if let data = try? Data(contentsOf: file), data.count < 1_500_000,
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = Array(saved.suffix(50))
        }
        #if canImport(KSCrashRecording)
        let crash = KSCrashConfiguration()
        crash.installPath = directory.appendingPathComponent("native", isDirectory: true).path
        crash.enableMemoryIntrospection = false
        crash.enableCompactBinaryImages = true
        crash.userInfoJSON = ["totono_environment": self.environment]
        try KSCrash.shared.install(with: crash)
        importCrashes()
        #endif
        schedule()
    }

    private static func queueDirectory(scope: String) throws -> URL {
        let files = FileManager.default
        #if os(Linux)
        let stateHome = ProcessInfo.processInfo.environment["XDG_STATE_HOME"]
        let base = stateHome.flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0, isDirectory: true) : nil }
            ?? files.homeDirectoryForCurrentUser.appendingPathComponent(".local/state", isDirectory: true)
        #else
        let base = try files.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        #endif
        let directory = base.appendingPathComponent("TotonoErrorReporting", isDirectory: true)
            .appendingPathComponent(scope, isDirectory: true)
        #if os(Linux)
        let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: permissions)
        try files.setAttributes(permissions, ofItemAtPath: directory.path)
        #else
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var protectedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(values)
        #endif
        return directory
    }

    public func addBreadcrumb(category: String, message: String) {
        breadcrumbs.append([
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "category": Self.clean(category, limit: 80),
            "message": Self.clean(message, limit: 512),
        ])
        if breadcrumbs.count > 50 { breadcrumbs.removeFirst() }
    }

    @discardableResult
    public func capture(_ error: Error, opaqueUserID: String? = nil) -> UUID? {
        let id = UUID()
        let date = Date()
        var event = envelope(id: id, date: date, severity: "error")
        event["exceptions"] = [[
            "type": Self.clean(String(reflecting: type(of: error)), limit: 160),
            "message": Self.clean(error.localizedDescription, limit: 2048),
            "frames": Thread.callStackSymbols.prefix(50).map { symbol in
                #if os(Linux)
                // Absolute addresses change each time the process starts.
                let frame = symbol.replacingOccurrences(of: #"\s+\[0x[0-9a-fA-F]+\]$"#, with: "", options: .regularExpression)
                #else
                let frame = symbol
                #endif
                return ["function": Self.clean(frame, limit: 256)]
            },
        ]]
        event["breadcrumbs"] = breadcrumbs
        if let opaqueUserID { event["user"] = ["id": Self.clean(opaqueUserID, limit: 200)] }
        return enqueue(event, id: id, date: date) ? id : nil
    }

    private func envelope(id: UUID, date: Date, severity: String) -> [String: Any] {
        #if os(Linux)
        let platform = "linux"
        let operatingSystem = "Linux"
        #else
        let platform = "ios"
        let operatingSystem = "iOS"
        #endif
        return [
            "id": id.uuidString.lowercased(), "timestamp": ISO8601DateFormatter().string(from: date),
            "platform": platform, "release": release, "build": build, "environment": environment,
            "severity": severity, "device": ["os": operatingSystem, "osVersion": ProcessInfo.processInfo.operatingSystemVersionString],
        ]
    }

    #if canImport(KSCrashRecording)
    private func importCrashes() {
        guard let store = KSCrash.shared.reportStore else { return }
        for number in store.reportIDs.suffix(5) {
            let reportID = number.int64Value
            guard let report = store.report(for: reportID)?.value as? [String: Any],
                  let converted = nativeEvent(report, reportID: reportID) else {
                store.deleteReport(with: reportID)
                continue
            }
            if enqueue(converted.event, id: converted.id, date: converted.date) {
                store.deleteReport(with: reportID)
            }
        }
    }

    private func nativeEvent(_ report: [String: Any], reportID: Int64) -> (event: [String: Any], id: UUID, date: Date)? {
        guard let metadata = report["report"] as? [String: Any],
              let timestamp = metadata["timestamp"] as? String,
              let crash = report["crash"] as? [String: Any] else { return nil }
        let clock = ISO8601DateFormatter()
        let standard = clock.date(from: timestamp)
        clock.formatOptions.insert(.withFractionalSeconds)
        guard let date = standard ?? clock.date(from: timestamp) else { return nil }
        let id = (metadata["id"] as? String).flatMap(UUID.init(uuidString:)) ?? Self.stableID("\(reportID):\(timestamp)")
        var event = envelope(id: id, date: date, severity: "fatal")
        if let system = report["system"] as? [String: Any] {
            event["release"] = Self.clean(system["bundle_short_version"] as? String ?? release, limit: 100)
            event["build"] = Self.clean(system["bundle_version"] as? String ?? build, limit: 100)
            event["device"] = [
                "os": "iOS",
                "osVersion": Self.clean(system["system_version"] as? String ?? "", limit: 100),
                "model": Self.clean(system["machine"] as? String ?? "", limit: 100),
            ]
        }
        if let user = report["user"] as? [String: Any], let environment = user["totono_environment"] as? String {
            event["environment"] = Self.clean(environment, limit: 64)
        }
        let rawImages = report["binary_images"] as? [[String: Any]] ?? []
        var imageIndex: [UInt64: Int] = [:]
        var images: [[String: String]] = []
        for raw in rawImages.prefix(256) {
            guard let uuid = (raw["uuid"] as? String).flatMap(UUID.init(uuidString:)),
                  let base = (raw["image_addr"] as? NSNumber)?.uint64Value,
                  let size = (raw["image_size"] as? NSNumber)?.uint64Value else { continue }
            let name = URL(fileURLWithPath: raw["name"] as? String ?? "").lastPathComponent
            let cpu = (raw["cpu_type"] as? NSNumber)?.intValue ?? 0
            let subtype = (raw["cpu_subtype"] as? NSNumber)?.intValue ?? 0
            let arch = cpu == 0x0100000c ? ((subtype & 255) == 2 ? "arm64e" : "arm64") : cpu == 0x01000007 ? "x86_64" : "unknown"
            imageIndex[base] = images.count
            images.append(["uuid": uuid.uuidString.lowercased(), "arch": arch, "base": Self.hex(base), "size": Self.hex(size), "name": Self.clean(name, limit: 256)])
        }
        let rawThreads = crash["threads"] as? [[String: Any]] ?? []
        let ordered = rawThreads.filter { ($0["crashed"] as? Bool) == true } + rawThreads.filter { ($0["crashed"] as? Bool) != true }
        let threads: [[String: Any]] = ordered.prefix(32).map { thread in
            let backtrace = thread["backtrace"] as? [String: Any]
            let contents = backtrace?["contents"] as? [[String: Any]] ?? []
            let frames: [[String: Any]] = contents.prefix(100).compactMap { raw in
                guard let address = (raw["instruction_addr"] as? NSNumber)?.uint64Value else { return nil }
                var frame: [String: Any] = ["instruction": Self.hex(address)]
                if let base = (raw["object_addr"] as? NSNumber)?.uint64Value, let index = imageIndex[base] {
                    frame["imageIndex"] = index
                    frame["inApp"] = (raw["object_name"] as? String)?.contains(".app/") ?? false
                }
                return frame
            }
            return ["crashed": thread["crashed"] as? Bool ?? false, "frames": frames]
        }
        let reason = crash["error"] as? [String: Any]
        event["images"] = images
        event["threads"] = threads
        event["exceptions"] = [[
            "type": Self.clean(reason?["type"] as? String ?? "NativeCrash", limit: 160),
            "message": Self.clean(reason?["reason"] as? String ?? "", limit: 2048),
            "frames": threads.first?["frames"] ?? [],
        ]]
        return (event, id, date)
    }

    #endif

    private func enqueue(_ event: [String: Any], id: UUID, date: Date) -> Bool {
        if date <= Date().addingTimeInterval(-30 * 86400) || !shouldSend(event) { return true }
        if entries.contains(where: { $0.id == id }) { return true }
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "events": [event]]),
              data.count < 900_000 else { return true }
        let previous = entries
        entries.append(Entry(id: id, date: date, body: data))
        entries = Array(entries.suffix(50))
        while entries.count > 1 && entries.reduce(0, { $0 + $1.body.count }) > 900_000 {
            entries.removeFirst()
        }
        if !persist() {
            entries = previous
            return false
        }
        schedule()
        return true
    }

    @discardableResult
    private func persist() -> Bool {
        do {
            #if os(Linux)
            let options: Data.WritingOptions = [.atomic]
            #else
            let options: Data.WritingOptions = [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            #endif
            try JSONEncoder().encode(entries).write(to: file, options: options)
            return true
        } catch {
            return false
        }
    }

    private func schedule() {
        guard !entries.isEmpty, task == nil, !sending else { return }
        let delay = max(1, min(86400, retryAt.timeIntervalSinceNow))
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.task = nil
            await self.flush()
        }
    }

    public func flush() async {
        guard !sending, Date() >= retryAt else { return }
        sending = true
        defer { sending = false; schedule() }
        entries.removeAll { $0.date <= Date().addingTimeInterval(-30 * 86400) }
        persist()
        for _ in 0..<10 {
            guard let entry = entries.first else { return }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "X-Totono-Error-Key")
            request.httpBody = entry.body
            do {
                let (_, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                if [202, 400, 413].contains(http.statusCode) {
                    entries.removeAll { $0.id == entry.id }
                    persist()
                    attempt = 0
                    retryAt = .distantPast
                    continue
                }
                if let delay = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init), delay.isFinite {
                    retryAt = Date().addingTimeInterval(min(86400, max(1, delay)))
                }
            } catch {
                // Keep the event for another attempt.
            }
            attempt = min(attempt + 1, 6)
            retryAt = max(retryAt, Date().addingTimeInterval(pow(2, Double(attempt))))
            return
        }
    }

    #if canImport(KSCrashRecording)
    private static func hex(_ value: UInt64) -> String { "0x" + String(value, radix: 16) }

    private static func stableID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    #endif

    private static func clean(_ value: String, limit: Int) -> String {
        var result = value
        let patterns = [
            #"(?i)\b(?:set-cookie|cookie|authorization)\s*[:=][^\r\n]*"#,
            #"(?i)\b(?:Bearer|Basic)\s+[^\s,;]+"#,
            #"(?i)\b(?:cookie|authorization|password|secret|token|session|credential|api[-_ ]?key)\s*[:=]\s*[^\s,;]+"#,
            #"\b[^\s@]+@[^\s@]+\.[^\s@]+"#,
            #"(?i)https?://[^\s<>]+"#,
        ]
        for pattern in patterns {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.prefix(limit))
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
