import XCTest
@testable import AntigravityRouterCore

final class SystemProxyStateTests: XCTestCase {
    func testSnapshotRestorePlanPreservesOriginalProxyState() {
        let snapshot = SystemProxySnapshot(
            id: "snap-1",
            services: [
                .init(
                    name: "Wi-Fi",
                    isServiceEnabled: true,
                    secureWebProxy: .init(enabled: true, host: "corp.proxy", port: 8443),
                    autoProxy: .init(enabled: true, url: "http://corp.proxy/proxy.pac"),
                    bypassDomains: ["localhost", "*.local"]
                )
            ],
            createdAt: Date(timeIntervalSince1970: 10)
        )

        let plan = SystemProxyPlanner.restorePlan(from: snapshot)

        XCTAssertEqual(plan.commands, [
            .setAutoProxyURL(service: "Wi-Fi", url: "http://corp.proxy/proxy.pac"),
            .setAutoProxyState(service: "Wi-Fi", enabled: true),
            .setSecureWebProxy(service: "Wi-Fi", host: "corp.proxy", port: 8443),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: true),
            .setBypassDomains(service: "Wi-Fi", domains: ["localhost", "*.local"])
        ])
        XCTAssertEqual(plan.recoveryCommands, [
            "networksetup -setautoproxyurl Wi-Fi http://corp.proxy/proxy.pac",
            "networksetup -setautoproxystate Wi-Fi on",
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
            .setAutoProxyURL(service: "Wi-Fi", url: "http://127.0.0.1:18080/proxy.pac"),
            .setAutoProxyState(service: "Wi-Fi", enabled: true)
        ])
        XCTAssertFalse(plan.commands.contains { command in
            if case .setSecureWebProxy = command { return true }
            if case .setSecureWebProxyState(_, true) = command { return true }
            return false
        })
        XCTAssertEqual(rollback.commands, [
            .setAutoProxyState(service: "Wi-Fi", enabled: false),
            .setSecureWebProxyState(service: "Wi-Fi", enabled: false),
            .setBypassDomains(service: "Wi-Fi", domains: [])
        ])
    }

    func testNetworkSetupArgumentsPreserveServiceNamesWithSpaces() {
        let command = SystemProxyCommand.setBypassDomains(service: "Thunderbolt Bridge", domains: ["localhost", "*.local"])

        XCTAssertEqual(command.networkSetupArguments, ["-setproxybypassdomains", "Thunderbolt Bridge", "localhost", "*.local"])
        XCTAssertEqual(command.networkSetupCommand, "networksetup -setproxybypassdomains 'Thunderbolt Bridge' localhost '*.local'")
    }

    func testNetworkSetupSnapshotParserHandlesProxyAndBypassOutput() throws {
        let proxy = try NetworkSetupSnapshotParser.parseSecureWebProxy(
            """
            Enabled: Yes
            Server: 127.0.0.1
            Port: 8877
            Authenticated Proxy Enabled: 0
            """
        )
        let bypassDomains = NetworkSetupSnapshotParser.parseBypassDomains(
            """
            localhost
            127.0.0.1
            ::1
            """
        )

        XCTAssertEqual(proxy, .init(enabled: true, host: "127.0.0.1", port: 8877))
        XCTAssertEqual(bypassDomains, ["localhost", "127.0.0.1", "::1"])
    }

    func testNetworkSetupSnapshotParserHandlesDisabledProxyAndNoBypassDomains() throws {
        let proxy = try NetworkSetupSnapshotParser.parseSecureWebProxy(
            """
            Enabled: No
            Server:
            Port: 0
            Authenticated Proxy Enabled: 0
            """
        )
        let bypassDomains = NetworkSetupSnapshotParser.parseBypassDomains("There aren't any bypass domains set on Wi-Fi.")

        XCTAssertEqual(proxy, .init(enabled: false, host: nil, port: nil))
        XCTAssertEqual(bypassDomains, [])
    }

    func testNetworkSetupSnapshotParserHandlesAutoProxyURL() throws {
        let enabledPAC = try NetworkSetupSnapshotParser.parseAutoProxyURL(
            """
            URL: http://127.0.0.1:8877/proxy.pac
            Enabled: Yes
            """
        )
        let disabledPAC = try NetworkSetupSnapshotParser.parseAutoProxyURL(
            """
            URL: (null)
            Enabled: No
            """
        )

        XCTAssertEqual(enabledPAC, .init(enabled: true, url: "http://127.0.0.1:8877/proxy.pac"))
        XCTAssertEqual(disabledPAC, .init(enabled: false, url: nil))
    }

    func testLegacySnapshotDecodingDefaultsMissingAutoProxyState() throws {
        let data = Data(
            """
            {
              "id": "legacy",
              "createdAt": 10,
              "services": [
                {
                  "name": "Wi-Fi",
                  "isServiceEnabled": true,
                  "secureWebProxy": {"enabled": false},
                  "bypassDomains": []
                }
              ]
            }
            """.utf8
        )

        let snapshot = try JSONDecoder().decode(SystemProxySnapshot.self, from: data)

        XCTAssertEqual(snapshot.services.first?.autoProxy, .init(enabled: false, url: nil))
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
        let failingCommand = SystemProxyCommand.setAutoProxyState(service: "Wi-Fi", enabled: true)
        let executor = RecordingSystemProxyExecutor(failingCommand: failingCommand)
        let manager = SystemProxyManager(executor: executor)

        XCTAssertThrowsError(try manager.enable(plan, originalSnapshot: snapshot)) { error in
            guard case let SystemProxyManagerError.enableFailed(command, appliedServices, rollback) = error else {
                return XCTFail("expected enableFailed, got \(error)")
            }
            XCTAssertEqual(command, failingCommand)
            XCTAssertEqual(appliedServices, ["Wi-Fi"])
            XCTAssertEqual(rollback.attempted.commands, [
                .setAutoProxyState(service: "Wi-Fi", enabled: false),
                .setSecureWebProxyState(service: "Wi-Fi", enabled: false),
                .setBypassDomains(service: "Wi-Fi", domains: [])
            ])
            XCTAssertEqual(rollback.results.map(\.command), rollback.attempted.commands)
            XCTAssertNil(rollback.failure)
        }

        XCTAssertEqual(executor.recordedCommands, [
            .setAutoProxyURL(service: "Wi-Fi", url: "http://127.0.0.1:8877/proxy.pac"),
            .setAutoProxyState(service: "Wi-Fi", enabled: true),
            .setAutoProxyState(service: "Wi-Fi", enabled: false),
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
                .setAutoProxyState(service: "Wi-Fi", enabled: true),
                .setSecureWebProxyState(service: "Wi-Fi", enabled: false)
            ]
        )
        let manager = SystemProxyManager(executor: executor)

        XCTAssertThrowsError(try manager.enable(plan, originalSnapshot: snapshot)) { error in
            guard case let SystemProxyManagerError.enableFailed(_, _, rollback) = error else {
                return XCTFail("expected enableFailed, got \(error)")
            }
            XCTAssertEqual(rollback.results.map(\.command), [
                .setAutoProxyState(service: "Wi-Fi", enabled: false)
            ])
            XCTAssertEqual(
                rollback.failure,
                .commandFailed(command: .setSecureWebProxyState(service: "Wi-Fi", enabled: false), status: 1, stderr: "boom")
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
