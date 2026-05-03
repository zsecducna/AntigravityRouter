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
            "networksetup -setproxybypassdomains Wi-Fi localhost *.local"
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
}
