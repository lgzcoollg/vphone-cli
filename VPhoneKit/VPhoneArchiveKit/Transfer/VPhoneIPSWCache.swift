import CryptoKit
import Darwin
import Foundation
import VPhoneCoreKit

/// Resolves a local IPSW or downloads one into a reusable, validated cache.
/// Source archives are never rewritten. Remote downloads become visible only
/// after their BuildManifest can be read and their transfer size checks out.
public enum VPhoneIPSWCache {
    public struct Archive: Sendable {
        public let file: URL
        public let version: String
        public let build: String
        /// `SupportedProductTypes`, such as `iPhone17,3`.
        public let productTypes: [String]
        /// Every build identity's `Info.DeviceClass`, such as `vresearch101ap`.
        public let deviceClasses: Set<String>
    }

    public enum Error: Swift.Error, LocalizedError {
        case unsupportedSource(String)
        case missingFile(URL)
        case invalidManifest(URL)
        case unexpectedHTTP(URL, Int)
        case incompleteDownload(URL, expected: Int64, actual: Int64)
        case swappedSources(iPhone: URL, cloudOS: URL)
        case notIPhoneSource(URL, productTypes: [String])
        case notCloudOSSource(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupportedSource(source): "Unsupported IPSW source: \(source). Use a local file path or an HTTP(S) URL."
            case let .missingFile(file): "IPSW not found at \(file.path). Check the path and try again."
            case let .invalidManifest(file): "\(file.path) is not a valid IPSW. Choose a different file."
            case let .unexpectedHTTP(url, _): "Unable to download the IPSW from \(url). Try again later."
            case let .incompleteDownload(url, expected, actual):
                "The IPSW download from \(url) is incomplete (\(actual) of \(expected) bytes). Try again."
            case let .swappedSources(iPhone, cloudOS):
                "The iPhone and cloudOS IPSWs are swapped: \(iPhone.lastPathComponent) is a cloudOS IPSW and \(cloudOS.lastPathComponent) is an iPhone IPSW. Swap the two sources, then try again."
            case let .notIPhoneSource(file, productTypes):
                "\(file.lastPathComponent) is not an \(VPhoneIPSWCache.iPhoneProductType) IPSW; it is for \(productTypes.isEmpty ? "no listed product" : productTypes.joined(separator: ", ")). Choose an \(VPhoneIPSWCache.iPhoneProductType) IPSW as the iPhone source."
            case let .notCloudOSSource(file):
                "\(file.lastPathComponent) is not a cloudOS IPSW: it has no \(VPhoneIPSWCache.cloudOSDeviceClass) build identity. Choose a cloudOS IPSW as the cloudOS source."
            }
        }
    }

    /// - Parameter label: what to call this archive on the progress line while it
    ///   downloads. Defaults to the file name from the URL. A local file, or one
    ///   already in the cache, never shows a line because nothing is transferred.
    public static func resolve(
        _ source: String,
        in cacheDirectory: URL,
        label: String? = nil,
        session: URLSession = URLSession(configuration: .ephemeral),
    ) async throws -> Archive {
        guard let url = URL(string: source), let scheme = url.scheme?.lowercased() else {
            return try inspect(URL(fileURLWithPath: source))
        }
        if scheme == "file" {
            return try inspect(url)
        }
        guard scheme == "http" || scheme == "https" else {
            throw Error.unsupportedSource(source)
        }

        let fm = FileManager.default
        try fm.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        // Before anything can fail: the directory is shared, and one made by a
        // sudo run must stay writable for the next run without sudo.
        try VPhoneHostFilePermissions.makeDirectoryAccessible(at: cacheDirectory)
        removeAbandonedDownloads(in: cacheDirectory)
        let cache = cacheDirectory.appendingPathComponent(cacheName(for: url))
        if let valid = try reuse(cache, in: cacheDirectory) {
            return valid
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3 * 60 * 60
        let pending = cacheDirectory.appendingPathComponent(".\(cache.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? fm.removeItem(at: pending) }
        guard fm.createFile(atPath: pending.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: pending)
        defer { try? output.close() }
        let (response, size) = try await download(
            request, into: output, session: session, label: label ?? url.lastPathComponent,
        )
        try output.close()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Error.unexpectedHTTP(url, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        if response.expectedContentLength > 0, size != response.expectedContentLength {
            throw Error.incompleteDownload(
                url,
                expected: response.expectedContentLength,
                actual: size,
            )
        }

        let metadata = try inspect(pending)
        do {
            try fm.moveItem(at: pending, to: cache)
        } catch {
            // Another machine's prepare finished the same URL first.
            if let valid = try reuse(cache, in: cacheDirectory) {
                return valid
            }
            throw error
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return Archive(
            file: cache,
            version: metadata.version,
            build: metadata.build,
            productTypes: metadata.productTypes,
            deviceClasses: metadata.deviceClasses,
        )
    }

    /// The cached archive when it is readable; an unreadable one is removed.
    private static func reuse(_ cache: URL, in _: URL) throws -> Archive? {
        guard FileManager.default.fileExists(atPath: cache.path) else { return nil }
        guard let valid = try? inspect(cache) else {
            try FileManager.default.removeItem(at: cache)
            return nil
        }
        try VPhoneHostFilePermissions.makeAccessible(at: cache)
        return valid
    }

    /// A download still in progress writes to its `.partial` file continuously.
    /// One untouched for an hour belongs to a process that was killed, and in a
    /// shared cache nothing else would ever remove it.
    private static func removeAbandonedDownloads(in cacheDirectory: URL) {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: cacheDirectory.path)) ?? []
        let cutoff = Date().addingTimeInterval(-60 * 60)
        for name in names where name.hasPrefix(".") && name.hasSuffix(".partial") {
            let file = cacheDirectory.appendingPathComponent(name)
            guard let modified = try? fm.attributesOfItem(atPath: file.path)[.modificationDate] as? Date,
                  modified < cutoff
            else { continue }
            try? fm.removeItem(at: file)
        }
    }

    public static func inspect(_ file: URL) throws -> Archive {
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw Error.missingFile(file)
        }
        guard let data = try? VPhoneArchiveReader.readMember("BuildManifest.plist", from: file),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any],
              let version = plist["ProductVersion"] as? String, !version.isEmpty,
              let build = plist["ProductBuildVersion"] as? String, !build.isEmpty
        else {
            throw Error.invalidManifest(file)
        }
        let identities = plist["BuildIdentities"] as? [[String: Any]] ?? []
        let deviceClasses = identities.compactMap { identity in
            ((identity["Info"] as? [String: Any])?["DeviceClass"] as? String)?.lowercased()
        }
        return Archive(
            file: file,
            version: version,
            build: build,
            productTypes: plist["SupportedProductTypes"] as? [String] ?? [],
            deviceClasses: Set(deviceClasses),
        )
    }

    // MARK: - Download

    /// Writes the body into `output` chunk by chunk as URLSession delivers it,
    /// so the IPSW lands in the cache's own volume with no temporary copy.
    /// Iterating `bytes(for:)` one byte at a time was CPU-bound (issue #524),
    /// and `download(for:)` stages the file in the system temporary directory,
    /// which may be another volume. A non-200 response returns before any body.
    private static func download(
        _ request: URLRequest,
        into output: FileHandle,
        session: URLSession,
        label: String,
    ) async throws -> (URLResponse, Int64) {
        let task = session.dataTask(with: request)
        let writer = DownloadWriter(output: output, label: label)
        task.delegate = writer
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                writer.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// URLSession calls one task's delegate serially, and `continuation` is set
    /// before the task resumes, so the mutable state is never shared.
    private final class DownloadWriter: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let output: FileHandle
        var continuation: CheckedContinuation<(URLResponse, Int64), Swift.Error>?
        private let label: String
        private var progress: DownloadProgress?
        private var response: URLResponse?
        private var written: Int64 = 0
        private var writeError: Swift.Error?

        init(output: FileHandle, label: String) {
            self.output = output
            self.label = label
        }

        func urlSession(
            _: URLSession,
            dataTask _: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void,
        ) {
            self.response = response
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            if ok, response.expectedContentLength > 0 {
                progress = DownloadProgress(label: label, expected: response.expectedContentLength)
                progress?.draw(written: 0)
            }
            completionHandler(ok ? .allow : .cancel)
        }

        func urlSession(_: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard writeError == nil else { return }
            do {
                try output.write(contentsOf: data)
                written += Int64(data.count)
                progress?.draw(written: written)
            } catch {
                writeError = error
                dataTask.cancel()
            }
        }

        func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Swift.Error?) {
            defer { progress = nil; continuation = nil }
            if let writeError {
                continuation?.resume(throwing: writeError)
            } else if let response, (response as? HTTPURLResponse)?.statusCode != 200 {
                // Cancelled on purpose in didReceive; the caller reports the status.
                continuation?.resume(returning: (response, 0))
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: (response, written))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    /// One line of download progress, redrawn in place with `\r`.
    ///
    /// The line is written only when standard output is a terminal, so a piped
    /// or redirected run stays byte-for-byte what it used to be: a script that
    /// captures `fw prepare` keeps its output, and a log never sees the redraws.
    /// The closing newline is emitted once, when the writer drops this.
    private final class DownloadProgress: @unchecked Sendable {
        private static let barCells = 24
        private static let labelLimit = 28

        private let label: String
        private let expected: Int64
        private let enabled: Bool
        private let started = Date()
        private var lastDraw = Date.distantPast
        private var drew = false

        init(label: String, expected: Int64) {
            self.label = label.count > Self.labelLimit
                ? String(label.prefix(Self.labelLimit - 1)) + "…"
                : label
            self.expected = expected
            enabled = isatty(STDOUT_FILENO) == 1
        }

        deinit {
            guard enabled, drew else { return }
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        func draw(written: Int64) {
            guard enabled else { return }
            // One write per chunk would be thousands of them. ~7 a second reads
            // as live without the download ever noticing; the final size always
            // gets through.
            let now = Date()
            guard written >= expected || now.timeIntervalSince(lastDraw) >= 0.15 else { return }
            lastDraw = now
            drew = true
            FileHandle.standardOutput.write(Data(("\r" + line(written: written)).utf8))
        }

        private func line(written: Int64) -> String {
            let fraction = expected > 0 ? min(1, max(0, Double(written) / Double(expected))) : 0
            let elapsed = max(0.001, Date().timeIntervalSince(started))
            let rate = Double(written) / elapsed

            let filled = Int((fraction * Double(Self.barCells)).rounded())
            let bar = String(repeating: "█", count: filled)
                + String(repeating: "░", count: Self.barCells - filled)

            var text = "\(label)  \(bar)  \(Int(fraction * 100))%"
            text += "  \(Self.bytes(written))/\(Self.bytes(expected))"
            text += "  \(Self.bytes(Int64(rate)))/s"
            if written >= expected {
                text += "  done"
            } else if fraction > 0 {
                text += "  ETA \(Self.duration(elapsed * (1 - fraction) / fraction))"
            }
            return text
        }

        private static func bytes(_ value: Int64) -> String {
            let units = ["B", "KB", "MB", "GB", "TB"]
            var value = Double(max(0, value))
            var unit = 0
            while value >= 1000, unit < units.count - 1 {
                value /= 1000
                unit += 1
            }
            return unit == 0 ? "\(Int(value)) \(units[unit])" : String(format: "%.1f %@", value, units[unit])
        }

        private static func duration(_ seconds: Double) -> String {
            guard seconds.isFinite, seconds > 0 else { return "?" }
            let total = Int(seconds.rounded())
            if total < 60 { return "\(total)s" }
            if total < 3600 { return "\(total / 60)m" }
            return "\(total / 3600)h \((total % 3600) / 60)m"
        }
    }

    // MARK: - Pairing

    /// The iPhone IPSW's product, and the cloudOS device class whose boot
    /// chain matches the VM's DFU hardware. The restore tree needs both.
    public static let iPhoneProductType = VPhoneFirmwareCatalog.device
    public static let cloudOSDeviceClass = "vresearch101ap"

    /// Checks each BuildManifest before anything is extracted, so a swapped
    /// or wrong IPSW fails at once with the fix instead of deep in the merge.
    public static func checkPair(iPhone: Archive, cloudOS: Archive) throws {
        let iPhoneIsPhone = iPhone.productTypes.contains(iPhoneProductType)
        let cloudOSIsCloudOS = cloudOS.deviceClasses.contains(cloudOSDeviceClass)
        if !iPhoneIsPhone, !cloudOSIsCloudOS,
           iPhone.deviceClasses.contains(cloudOSDeviceClass),
           cloudOS.productTypes.contains(iPhoneProductType)
        {
            throw Error.swappedSources(iPhone: iPhone.file, cloudOS: cloudOS.file)
        }
        guard iPhoneIsPhone else {
            throw Error.notIPhoneSource(iPhone.file, productTypes: iPhone.productTypes)
        }
        guard cloudOSIsCloudOS else {
            throw Error.notCloudOSSource(cloudOS.file)
        }
    }

    static func cacheName(for url: URL) -> String {
        let base = url.lastPathComponent
        let stem = base.lowercased().hasSuffix(".ipsw") ? String(base.dropLast(5)) : base
        let safe = String(stem.prefix(48).unicodeScalars.map { scalar in
            let value = scalar.value
            return (value >= 48 && value <= 57) || (value >= 65 && value <= 90)
                || (value >= 97 && value <= 122) || value == 45 || value == 46 || value == 95
                ? Character(scalar) : "_"
        })
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let suffix = digest.prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(safe.isEmpty ? "firmware" : safe)-\(suffix).ipsw"
    }
}
