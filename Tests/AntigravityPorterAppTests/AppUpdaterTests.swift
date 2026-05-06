import CryptoKit
import Foundation
import XCTest
@testable import AntigravityPorterApp

final class AppUpdaterTests: XCTestCase {
    func testVersionComparisonHandlesVPrefixAndPatchWidth() throws {
        XCTAssertGreaterThan(try XCTUnwrap(AppVersion("v0.1.10")), try XCTUnwrap(AppVersion("0.1.9")))
        XCTAssertEqual(try XCTUnwrap(AppVersion("v0.1.1")), try XCTUnwrap(AppVersion("0.1.1")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("0.1.1")), try XCTUnwrap(AppVersion("0.1.2")))
    }

    func testAutomaticUpdateIntervalIsOneHour() {
        XCTAssertEqual(AppUpdateController.checkInterval, 60 * 60)
    }

    @MainActor
    func testControllerSkipsUpdateCheckWhenVersionIsUnknown() {
        let controller = AppUpdateController(
            currentVersion: nil,
            service: AppUpdateService(client: FakeAppUpdateClient.empty, verifier: PassingAppUpdateVerifier()),
            defaults: UserDefaults(suiteName: "AntigravityRouterUpdateTests-\(UUID().uuidString)") ?? .standard
        )

        controller.checkNow(forceOpen: true)

        XCTAssertEqual(controller.currentVersionDisplay, "unknown")
        XCTAssertEqual(controller.statusMessage, "check skipped: app version unknown")
    }

    @MainActor
    func testBackgroundUpdateDoesNotOpenInstaller() {
        var openedURLs: [URL] = []
        let controller = AppUpdateController(
            currentVersion: "0.1.1",
            service: AppUpdateService(client: FakeAppUpdateClient.empty, verifier: PassingAppUpdateVerifier()),
            defaults: UserDefaults(suiteName: "AntigravityRouterUpdateTests-\(UUID().uuidString)") ?? .standard,
            openDMG: { url in
                openedURLs.append(url)
                return true
            }
        )
        let dmgURL = URL(fileURLWithPath: "/tmp/AntigravityRouter-v0.1.2-macos-arm64.dmg")

        controller.handle(.updateReady(version: "v0.1.2", dmgURL: dmgURL), forceOpen: false)

        XCTAssertTrue(openedURLs.isEmpty)
        XCTAssertEqual(controller.statusMessage, "installer ready v0.1.2")
    }

    @MainActor
    func testUpToDateStatusUsesUserVisibleWording() {
        let controller = AppUpdateController(
            currentVersion: "0.1.2",
            service: AppUpdateService(client: FakeAppUpdateClient.empty, verifier: PassingAppUpdateVerifier()),
            defaults: UserDefaults(suiteName: "AntigravityRouterUpdateTests-\(UUID().uuidString)") ?? .standard
        )

        controller.handle(.upToDate(version: "v0.1.2"), forceOpen: true)

        XCTAssertEqual(controller.statusMessage, "up-to-date (v0.1.2)")
    }

    @MainActor
    func testManualUpdateOpensInstaller() {
        var openedURLs: [URL] = []
        let controller = AppUpdateController(
            currentVersion: "0.1.1",
            service: AppUpdateService(client: FakeAppUpdateClient.empty, verifier: PassingAppUpdateVerifier()),
            defaults: UserDefaults(suiteName: "AntigravityRouterUpdateTests-\(UUID().uuidString)") ?? .standard,
            openDMG: { url in
                openedURLs.append(url)
                return true
            }
        )
        let dmgURL = URL(fileURLWithPath: "/tmp/AntigravityRouter-v0.1.2-macos-arm64.dmg")

        controller.handle(.updateReady(version: "v0.1.2", dmgURL: dmgURL), forceOpen: true)

        XCTAssertEqual(openedURLs, [dmgURL])
        XCTAssertEqual(controller.statusMessage, "opened installer v0.1.2")
    }

    func testReleaseDecodesGitHubSnakeCaseFields() throws {
        let json = Data("""
        {
          "tag_name": "v0.1.2",
          "draft": false,
          "prerelease": false,
          "assets": [
            {
              "name": "AntigravityRouter-v0.1.2-macos-arm64.dmg",
              "browser_download_url": "https://example.test/app.dmg",
              "digest": "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            }
          ]
        }
        """.utf8)
        let release = try JSONDecoder().decode(AppRelease.self, from: json)

        XCTAssertEqual(release.tagName, "v0.1.2")
        XCTAssertEqual(release.assets.first?.browserDownloadURL.absoluteString, "https://example.test/app.dmg")
        XCTAssertEqual(release.assets.first?.digest, "sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testReleaseSelectsMacOSArm64DMGAndChecksum() throws {
        let dmg = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg",
            browserDownloadURL: URL(string: "https://example.test/app.dmg")!
        )
        let release = AppRelease(tagName: "v0.1.2", assets: [
            AppRelease.Asset(name: "AntigravityRouter-v0.1.2-macos-arm64.tar.gz", browserDownloadURL: URL(string: "https://example.test/app.tar.gz")!),
            dmg,
            AppRelease.Asset(name: "AntigravityRouter-v0.1.2-macos-arm64.dmg.sha256", browserDownloadURL: URL(string: "https://example.test/app.dmg.sha256")!)
        ])

        XCTAssertEqual(release.installDMGAsset(for: "v0.1.2"), dmg)
        XCTAssertEqual(release.sha256Asset(for: dmg)?.name, "AntigravityRouter-v0.1.2-macos-arm64.dmg.sha256")
    }

    func testReleaseRejectsDMGForWrongProductOrTag() {
        let release = AppRelease(tagName: "v0.1.2", assets: [
            AppRelease.Asset(name: "OtherRouter-v0.1.2-macos-arm64.dmg", browserDownloadURL: URL(string: "https://example.test/other.dmg")!),
            AppRelease.Asset(name: "AntigravityRouter-v0.1.1-macos-arm64.dmg", browserDownloadURL: URL(string: "https://example.test/old.dmg")!)
        ])

        XCTAssertNil(release.installDMGAsset(for: "v0.1.2"))
    }

    func testRemoteNamesAreSanitizedBeforeLocalFileUse() {
        XCTAssertEqual(AppUpdateService.safePathComponent("../v0.1.2", fallback: "release"), "v0.1.2")
        XCTAssertEqual(AppUpdateService.safePathComponent("/tmp/AntigravityRouter.dmg", fallback: "update.dmg"), "AntigravityRouter.dmg")
        XCTAssertEqual(AppUpdateService.safePathComponent(".", fallback: "release"), "release")
    }

    func testCheckDownloadsAndVerifiesNewerDMG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dmgData = Data("fake dmg".utf8)
        let checksum = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        let dmg = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg",
            browserDownloadURL: URL(string: "https://example.test/app.dmg")!
        )
        let checksumAsset = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg.sha256",
            browserDownloadURL: URL(string: "https://example.test/app.dmg.sha256")!
        )
        let client = FakeAppUpdateClient(
            release: AppRelease(tagName: "v0.1.2", assets: [dmg, checksumAsset]),
            downloads: [dmg.name: dmgData],
            assetData: [checksumAsset.name: Data("\(checksum)  \(dmg.name)\n".utf8)]
        )
        let service = AppUpdateService(client: client, verifier: PassingAppUpdateVerifier(), updatesDirectory: directory)

        let result = try await service.checkForUpdate(currentVersion: "0.1.1")

        guard case let .updateReady(version, dmgURL) = result else {
            return XCTFail("expected updateReady, got \(result)")
        }
        XCTAssertEqual(version, "v0.1.2")
        XCTAssertEqual(try Data(contentsOf: dmgURL), dmgData)
    }

    func testCheckVerifiesWithGitHubDigestFallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dmgData = Data("fake dmg".utf8)
        let checksum = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        let dmg = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg",
            browserDownloadURL: URL(string: "https://example.test/app.dmg")!,
            digest: "sha256:\(checksum)"
        )
        let client = FakeAppUpdateClient(
            release: AppRelease(tagName: "v0.1.2", assets: [dmg]),
            downloads: [dmg.name: dmgData],
            assetData: [:]
        )
        let service = AppUpdateService(client: client, verifier: PassingAppUpdateVerifier(), updatesDirectory: directory)

        let result = try await service.checkForUpdate(currentVersion: "0.1.1")

        guard case let .updateReady(version, dmgURL) = result else {
            return XCTFail("expected updateReady, got \(result)")
        }
        XCTAssertEqual(version, "v0.1.2")
        XCTAssertEqual(try Data(contentsOf: dmgURL), dmgData)
    }

    func testCheckRejectsFailedNotarizationAndDeletesDMG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dmgData = Data("fake dmg".utf8)
        let checksum = SHA256.hash(data: dmgData).map { String(format: "%02x", $0) }.joined()
        let dmg = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg",
            browserDownloadURL: URL(string: "https://example.test/app.dmg")!,
            digest: "sha256:\(checksum)"
        )
        let client = FakeAppUpdateClient(
            release: AppRelease(tagName: "v0.1.2", assets: [dmg]),
            downloads: [dmg.name: dmgData],
            assetData: [:]
        )
        let service = AppUpdateService(
            client: client,
            verifier: FailingAppUpdateVerifier(),
            updatesDirectory: directory
        )

        do {
            _ = try await service.checkForUpdate(currentVersion: "0.1.1")
            XCTFail("expected notarization failure")
        } catch let error as AppUpdateError {
            guard case .notarizationCheckFailed = error else {
                return XCTFail("expected notarization failure, got \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("v0.1.2").appendingPathComponent(dmg.name).path))
        }
    }

    func testCheckRejectsChecksumMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AntigravityRouterUpdateTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let dmg = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg",
            browserDownloadURL: URL(string: "https://example.test/app.dmg")!
        )
        let checksumAsset = AppRelease.Asset(
            name: "AntigravityRouter-v0.1.2-macos-arm64.dmg.sha256",
            browserDownloadURL: URL(string: "https://example.test/app.dmg.sha256")!
        )
        let client = FakeAppUpdateClient(
            release: AppRelease(tagName: "v0.1.2", assets: [dmg, checksumAsset]),
            downloads: [dmg.name: Data("fake dmg".utf8)],
            assetData: [checksumAsset.name: Data("\(String(repeating: "0", count: 64))  \(dmg.name)\n".utf8)]
        )
        let service = AppUpdateService(client: client, verifier: PassingAppUpdateVerifier(), updatesDirectory: directory)

        do {
            _ = try await service.checkForUpdate(currentVersion: "0.1.1")
            XCTFail("expected checksum mismatch")
        } catch let error as AppUpdateError {
            guard case .checksumMismatch = error else {
                return XCTFail("expected checksum mismatch, got \(error)")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("v0.1.2").appendingPathComponent(dmg.name).path))
        }
    }
}

struct PassingAppUpdateVerifier: AppUpdateVerifying {
    func verifyInstallDMG(at fileURL: URL) async throws {}
}

struct FailingAppUpdateVerifier: AppUpdateVerifying {
    func verifyInstallDMG(at fileURL: URL) async throws {
        throw AppUpdateError.notarizationCheckFailed(status: 1, output: "", error: "rejected")
    }
}

struct FakeAppUpdateClient: AppUpdateFetching {
    static let empty = FakeAppUpdateClient(
        release: AppRelease(tagName: "v0.0.0", assets: []),
        downloads: [:],
        assetData: [:]
    )

    var release: AppRelease
    var downloads: [String: Data]
    var assetData: [String: Data]

    func fetchLatestRelease() async throws -> AppRelease {
        release
    }

    func fetchAssetData(_ asset: AppRelease.Asset) async throws -> Data {
        assetData[asset.name] ?? Data()
    }

    func downloadAsset(_ asset: AppRelease.Asset, to directory: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(asset.name)
        try downloads[asset.name, default: Data()].write(to: destination)
        return destination
    }
}
