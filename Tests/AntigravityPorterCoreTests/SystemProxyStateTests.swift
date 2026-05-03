import XCTest
@testable import AntigravityPorterCore

final class SystemProxyStateTests: XCTestCase {
    func testSnapshotRestorePlanPreservesOriginalProxyState() {
        let snapshot = SystemProxySnapshot(
            id: "snap-1",
            services: [
                .init(
                    name: "Wi-Fi",
                    isServiceEnabled: true,
                    secureWebProxy: .init(enabled: true, host: "corp.proxy", port: 8443),
                    bypassDomains: ["localhost", "*.local"]
                )
            ],
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let plan = SystemProxyPlanner.restorePlan(from: snapshot)

        XCTAssertEqual(plan.commands, [
            .setSecureWebProxy(service: "Wi-Fi", host: "corp.proxy", port: 8443),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: true),
            .setBypassDomains(service: "Wi-Fi", domains: ["localhost", "*.local"])
        ])
        XCTAssertEqual(plan.recoveryCommands, [
            "networksetup -setsecurewebproxy Wi-Fi corp.proxy 8443",
            "networksetup -setsecurewebproxystate Wi-Fi on",
            "networksetup -setproxybypassdomains Wi-Fi localhost '*.local'"
        ])
    }

    func testEnablePlanSkipsDisabledServicesAndRollsBackMutatedServicesOnFailure() {
        let snapshot = SystemProxySnapshot(
            id: "snap-2",
            services: [
                .init(name: "Wi-Fi", isServiceEnabled: true, secureWebProxy: .init(enabled: false, host: nil, port: nil), bypassDomains: []),
                .init(name: "Thunderbolt Bridge", isServiceEnabled: false, secureWebProxy: .init(enabled: false, host: nil, port: nil), bypassDomains: [])
            ],
            createdAt: Date(timeIntervalSince1970: 20)
        )

        let plan = SystemProxyPlanner.enablePlan(from: snapshot, proxyHost: "127.0.0.1", proxyPort: 18080, bypassDomains: ["localhost"])
        let rollback = SystemProxyPlanner.rollbackPlan(afterFailedEnable: plan, originalSnapshot: snapshot, mutatedServices: ["Wi-Fi"])

        XCTAssertEqual(plan.commands, [
            .setSecureWebProxy(service: "Wi-Fi", host: "127.0.0.1", port: 18080),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: true),
            .setBypassDomains(service: "Wi-Fi", domains: ["localhost"])
        ])
        XCTAssertEqual(rollback.commands, [
            .setSecureWebProxyState(service: "Wi-Fi", enabled: false),
            .setBypassDomains(service: "Wi-Fi", domains: [])
        ])
    }

    func testNetworkSetupArgumentsPreserveServiceNamesWithSpaces() {
        let command = SystemProxyCommand.setBypassDomains(service: "Thunderbolt Bridge", domains: ["localhost", "*.local"])

        XCTAssertEqual(command.networkSetupArguments, ["-setproxybypassdomains", "Thunderbolt Bridge", "localhost", "*.local"])
        XCTAssertEqual(command.networkSetupCommand, "networksetup -setproxybypassdomains 'Thunderbolt Bridge' localhost '*.local'")
    }

    func testManagerRollsBackMutatedServicesWhenEnableCommandFails() {
        let snapshot = SystemProxySnapshot(
            id: "snap-3",
            services: [
                .init(name: "Wi-Fi", isServiceEnabled: true, secureWebProxy: .init(enabled: false, host: nil, port: nil), bypassDomains: [])
            ],
            createdAt: Date(timeIntervalSince1970: 30)
        )
        let plan = SystemProxyPlanner.enablePlan(
            from: snapshot,
            proxyHost: "127.0.0.1",
            proxyPort: 8877,
            bypassDomains: ["localhost"]
        )
        let failingCommand = SystemProxyCommand.setSecureWebProxyState(service: "Wi-Fi", enabled: true)
        let executor = RecordingSystemProxyExecutor(failingCommand: failingCommand)
        let manager = SystemProxyManager(executor: executor)

        XCTAssertThrowsError(try manager.enable(plan, originalSnapshot: snapshot)) { error in
            guard case let SystemProxyManagerError.enableFailed(command, appliedServices, rollback) = error else {
                return XCTFail("expected enableFailed, got \(error)")
            }
            XCTAssertEqual(command, failingCommand)
            XCTAssertEqual(appliedServices, ["Wi-Fi"])
            XCTAssertEqual(rollback.attempted.commands, [
                .setSecureWebProxyState(service: "Wi-Fi", enabled: false),
                .setBypassDomains(service: "Wi-Fi", domains: [])
            ])
            XCTAssertEqual(rollback.results.map(\.command), rollback.attempted.commands)
            XCTAssertNil(rollback.failure)
        }

        XCTAssertEqual(executor.recordedCommands, [
            .setSecureWebProxy(service: "Wi-Fi", host: "127.0.0.1", port: 8877),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: true),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: false),
            .setBypassDomains(service: "Wi-Fi", domains: [])
        ])
    }

    func testManagerReportsRollbackFailureAfterPartialEnableFailure() {
        let snapshot = SystemProxySnapshot(
            id: "snap-4",
            services: [
                .init(name: "Wi-Fi", isServiceEnabled: true, secureWebProxy: .init(enabled: false, host: nil, port: nil), bypassDomains: [])
            ],
            createdAt: Date(timeIntervalSince1970: 40)
        )
        let plan = SystemProxyPlanner.enablePlan(
            from: snapshot,
            proxyHost: "127.0.0.1",
            proxyPort: 8877,
            bypassDomains: ["localhost"]
        )
        let executor = RecordingSystemProxyExecutor(
            failingCommands: [
                .setSecureWebProxyState(service: "Wi-Fi", enabled: true),
                .setBypassDomains(service: "Wi-Fi", domains: [])
            ]
        )
        let manager = SystemProxyManager(executor: executor)

        XCTAssertThrowsError(try manager.enable(plan, originalSnapshot: snapshot)) { error in
            guard case let SystemProxyManagerError.enableFailed(_, _, rollback) = error else {
                return XCTFail("expected enableFailed, got \(error)")
            }
            XCTAssertEqual(rollback.results.map(\.command), [
                .setSecureWebProxyState(service: "Wi-Fi", enabled: false)
            ])
            XCTAssertEqual(
                rollback.failure,
                .commandFailed(command: .setBypassDomains(service: "Wi-Fi", domains: []), status: 1, stderr: "boom")
            )
        }
    }
}

final class RecordingSystemProxyExecutor: SystemProxyCommandExecuting, @unchecked Sendable {
    private let failingCommands: [SystemProxyCommand]
    private(set) var recordedCommands: [SystemProxyCommand] = []

    init(failingCommand: SystemProxyCommand? = nil) {
        self.failingCommands = failingCommand.map { [$0] } ?? []
    }

    init(failingCommands: [SystemProxyCommand]) {
        self.failingCommands = failingCommands
    }

    func run(_ command: SystemProxyCommand) throws -> SystemProxyCommandResult {
        recordedCommands.append(command)
        if failingCommands.contains(command) {
            throw SystemProxyManagerError.commandFailed(command: command, status: 1, stderr: "boom")
        }
        return SystemProxyCommandResult(command: command)
    }
}
