import AppKit
import CryptoKit
import Foundation

struct AppVersion: Comparable, Equatable, Sendable {
    let components: [Int]

    init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let versionPart = withoutPrefix.split(separator: "-", maxSplits: 1).first ?? Substring(withoutPrefix)
        let parsed = versionPart.split(separator: ".").map { Int($0) }
        guard !parsed.isEmpty, parsed.allSatisfy({ $0 != nil }) else { return nil }
        self.components = parsed.map { $0 ?? 0 }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right {
                return left < right
            }
        }
        return false
    }
}

struct AppRelease: Decodable, Equatable, Sendable {
    struct Asset: Decodable, Equatable, Sendable {
        private enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case digest
        }

        var name: String
        var browserDownloadURL: URL
        var digest: String?

        init(name: String, browserDownloadURL: URL, digest: String? = nil) {
            self.name = name
            self.browserDownloadURL = browserDownloadURL
            self.digest = digest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case assets
    }

    var tagName: String
    var draft: Bool
    var prerelease: Bool
    var assets: [Asset]

    init(tagName: String, draft: Bool = false, prerelease: Bool = false, assets: [Asset]) {
        self.tagName = tagName
        self.draft = draft
        self.prerelease = prerelease
        self.assets = assets
    }

    func installDMGAsset(for tagName: String) -> Asset? {
        let expectedName = "AntigravityRouter-\(tagName)-macos-arm64.dmg"
        return assets.first { asset in
            asset.name == expectedName
        }
    }

    func sha256Asset(for asset: Asset) -> Asset? {
        assets.first { candidate in
            candidate.name == "\(asset.name).sha256"
        }
    }
}

protocol AppUpdateFetching: Sendable {
    func fetchLatestRelease() async throws -> AppRelease
    func fetchAssetData(_ asset: AppRelease.Asset) async throws -> Data
    func downloadAsset(_ asset: AppRelease.Asset, to directory: URL) async throws -> URL
}

protocol AppUpdateVerifying: Sendable {
    func verifyInstallDMG(at fileURL: URL) async throws
}

struct GitHubAppUpdateClient: AppUpdateFetching {
    private let latestReleaseURL = URL(string: "https://api.github.com/repos/zsecducna/AntigravityRouter/releases/latest")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchLatestRelease() async throws -> AppRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AntigravityRouter", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response)
        return try JSONDecoder().decode(AppRelease.self, from: data)
    }

    func fetchAssetData(_ asset: AppRelease.Asset) async throws -> Data {
        var request = URLRequest(url: asset.browserDownloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AntigravityRouter", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validateHTTP(response)
        return data
    }

    func downloadAsset(_ asset: AppRelease.Asset, to directory: URL) async throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: asset.browserDownloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("AntigravityRouter", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        try Self.validateHTTP(response)
        let destination = directory.appendingPathComponent(AppUpdateService.safePathComponent(asset.name, fallback: "update.dmg"))
        try? fileManager.removeItem(at: destination)
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AppUpdateError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AppUpdateError.badStatus(http.statusCode)
        }
    }
}

struct SPCTLAppUpdateVerifier: AppUpdateVerifying {
    func verifyInstallDMG(at fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/spctl")
            process.arguments = [
                "--assess",
                "--type", "open",
                "--context", "context:primary-signature",
                "--verbose=4",
                fileURL.path
            ]
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()

            let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw AppUpdateError.notarizationCheckFailed(
                    status: process.terminationStatus,
                    output: output,
                    error: error
                )
            }
        }.value
    }
}

enum AppUpdateResult: Equatable, Sendable {
    case upToDate(version: String)
    case updateReady(version: String, dmgURL: URL)
}

enum AppUpdateError: Error, LocalizedError, Equatable, Sendable {
    case invalidCurrentVersion(String)
    case invalidReleaseVersion(String)
    case draftOrPrerelease(String)
    case missingDMGAsset(String)
    case missingChecksum(String)
    case checksumMismatch(expected: String, actual: String)
    case notarizationCheckFailed(status: Int32, output: String, error: String)
    case invalidResponse
    case badStatus(Int)

    var errorDescription: String? {
        switch self {
        case let .invalidCurrentVersion(version):
            return "invalid current version \(version)"
        case let .invalidReleaseVersion(version):
            return "invalid release version \(version)"
        case let .draftOrPrerelease(version):
            return "release \(version) is draft or prerelease"
        case let .missingDMGAsset(version):
            return "release \(version) has no macOS arm64 DMG"
        case let .missingChecksum(asset):
            return "release asset \(asset) has no SHA-256 checksum"
        case let .checksumMismatch(expected, actual):
            return "update checksum mismatch expected=\(expected) actual=\(actual)"
        case let .notarizationCheckFailed(status, output, error):
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? output.trimmingCharacters(in: .whitespacesAndNewlines)
                : error.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.isEmpty {
                return "update notarization check failed (\(status))"
            }
            return "update notarization check failed (\(status)): \(detail)"
        case .invalidResponse:
            return "invalid update server response"
        case let .badStatus(status):
            return "update server returned HTTP \(status)"
        }
    }
}

struct AppUpdateService: Sendable {
    var client: any AppUpdateFetching
    var verifier: any AppUpdateVerifying
    var updatesDirectory: URL

    init(
        client: any AppUpdateFetching = GitHubAppUpdateClient(),
        verifier: any AppUpdateVerifying = SPCTLAppUpdateVerifier(),
        updatesDirectory: URL = AppUpdateService.defaultUpdatesDirectory()
    ) {
        self.client = client
        self.verifier = verifier
        self.updatesDirectory = updatesDirectory
    }

    func checkForUpdate(currentVersion: String) async throws -> AppUpdateResult {
        guard let current = AppVersion(currentVersion) else {
            throw AppUpdateError.invalidCurrentVersion(currentVersion)
        }
        let release = try await client.fetchLatestRelease()
        guard !release.draft, !release.prerelease else {
            throw AppUpdateError.draftOrPrerelease(release.tagName)
        }
        guard let latest = AppVersion(release.tagName) else {
            throw AppUpdateError.invalidReleaseVersion(release.tagName)
        }
        guard latest > current else {
            return .upToDate(version: release.tagName)
        }
        guard let dmgAsset = release.installDMGAsset(for: release.tagName) else {
            throw AppUpdateError.missingDMGAsset(release.tagName)
        }

        let releaseDirectory = updatesDirectory.appendingPathComponent(
            Self.safePathComponent(release.tagName, fallback: "release"),
            isDirectory: true
        )
        let dmgURL = try await client.downloadAsset(dmgAsset, to: releaseDirectory)
        let expectedChecksum = try await expectedSHA256(for: dmgAsset, in: release)
        let actualChecksum = try Self.sha256Hex(fileURL: dmgURL)
        guard expectedChecksum.caseInsensitiveCompare(actualChecksum) == .orderedSame else {
            try? FileManager.default.removeItem(at: dmgURL)
            throw AppUpdateError.checksumMismatch(expected: expectedChecksum, actual: actualChecksum)
        }
        do {
            try await verifier.verifyInstallDMG(at: dmgURL)
        } catch {
            try? FileManager.default.removeItem(at: dmgURL)
            throw error
        }
        return .updateReady(version: release.tagName, dmgURL: dmgURL)
    }

    private func expectedSHA256(for asset: AppRelease.Asset, in release: AppRelease) async throws -> String {
        if let digest = asset.digest, let checksum = Self.parseSHA256(digest) {
            return checksum
        }
        if let checksumAsset = release.sha256Asset(for: asset) {
            let data = try await client.fetchAssetData(checksumAsset)
            if let checksum = Self.parseSHA256(String(decoding: data, as: UTF8.self)) {
                return checksum
            }
        }
        throw AppUpdateError.missingChecksum(asset.name)
    }

    static func parseSHA256(_ text: String) -> String? {
        let pattern = #"[A-Fa-f0-9]{64}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range]).lowercased()
    }

    static func sha256Hex(fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func safePathComponent(_ value: String, fallback: String) -> String {
        let candidate = (value as NSString).lastPathComponent
        guard !candidate.isEmpty, candidate != ".", candidate != ".." else {
            return fallback
        }
        return candidate
    }

    static func defaultUpdatesDirectory() -> URL {
        let supportRoot = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return supportRoot
            .appendingPathComponent("AntigravityRouter", isDirectory: true)
            .appendingPathComponent("Updates", isDirectory: true)
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    nonisolated static let checkInterval: TimeInterval = 60 * 60
    private static let openedVersionKey = "AntigravityRouter.update.openedVersion"

    @Published private(set) var statusMessage = "not checked"
    @Published private(set) var isChecking = false
    @Published private(set) var lastCheckedAt: Date?

    let currentVersion: String?
    var currentVersionDisplay: String { currentVersion ?? "unknown" }
    private let service: AppUpdateService
    private let defaults: UserDefaults
    private let openDMG: @MainActor (URL) -> Bool
    private let quitForInstall: @MainActor () -> Void
    private var timer: Timer?

    init(
        currentVersion: String? = AppUpdateController.bundleShortVersion(),
        service: AppUpdateService = AppUpdateService(),
        defaults: UserDefaults = .standard,
        openDMG: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        quitForInstall: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        self.currentVersion = currentVersion
        self.service = service
        self.defaults = defaults
        self.openDMG = openDMG
        self.quitForInstall = quitForInstall
    }

    func startAutomaticChecks() {
        guard timer == nil else { return }
        checkNow(forceOpen: false)
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkNow(forceOpen: false)
            }
        }
    }

    func checkNow(forceOpen: Bool) {
        guard !isChecking else { return }
        guard let currentVersion else {
            lastCheckedAt = Date()
            statusMessage = "check skipped: app version unknown"
            return
        }
        isChecking = true
        statusMessage = "checking..."
        Task {
            do {
                let result = try await service.checkForUpdate(currentVersion: currentVersion)
                await MainActor.run {
                    self.handle(result, forceOpen: forceOpen)
                }
            } catch {
                await MainActor.run {
                    self.lastCheckedAt = Date()
                    self.statusMessage = "check failed: \(error.localizedDescription)"
                    self.isChecking = false
                }
            }
        }
    }

    func handle(_ result: AppUpdateResult, forceOpen: Bool) {
        lastCheckedAt = Date()
        switch result {
        case let .upToDate(version):
            statusMessage = "up-to-date (\(version))"
        case let .updateReady(version, dmgURL):
            let alreadyOpened = defaults.string(forKey: Self.openedVersionKey) == version
            if forceOpen {
                if openDMG(dmgURL) {
                    defaults.set(version, forKey: Self.openedVersionKey)
                    statusMessage = "opened installer \(version); quitting app for install"
                    quitForInstall()
                } else {
                    statusMessage = "downloaded \(version), open failed"
                }
            } else {
                statusMessage = alreadyOpened ? "installer already opened \(version)" : "installer ready \(version)"
            }
        }
        isChecking = false
    }

    static func bundleShortVersion(in bundle: Bundle = .main) -> String? {
        guard let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              AppVersion(version) != nil
        else {
            return nil
        }
        return version
    }
}
