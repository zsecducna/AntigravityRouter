import Foundation

public struct SecureWebProxyState: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var host: String?
    public var port: Int?

    public init(enabled: Bool, host: String?, port: Int?) {
        self.enabled = enabled
        self.host = host
        self.port = port
    }
}

public struct SystemProxyServiceSnapshot: Equatable, Codable, Sendable {
    public var name: String
    public var isServiceEnabled: Bool
    public var secureWebProxy: SecureWebProxyState
    public var bypassDomains: [String]

    public init(name: String, isServiceEnabled: Bool, secureWebProxy: SecureWebProxyState, bypassDomains: [String]) {
        self.name = name
        self.isServiceEnabled = isServiceEnabled
        self.secureWebProxy = secureWebProxy
        self.bypassDomains = bypassDomains
    }
}

public struct SystemProxySnapshot: Equatable, Codable, Sendable {
    public var id: String
    public var services: [SystemProxyServiceSnapshot]
    public var createdAt: Date

    public init(id: String, services: [SystemProxyServiceSnapshot], createdAt: Date) {
        self.id = id
        self.services = services
        self.createdAt = createdAt
    }
}

public enum SystemProxyCommand: Equatable, Sendable {
    case setSecureWebProxy(service: String, host: String, port: Int)
    case setSecureWebProxyState(service: String, enabled: Bool)
    case setBypassDomains(service: String, domains: [String])

    public var networkSetupCommand: String {
        switch self {
        case let .setSecureWebProxy(service, host, port):
            "networksetup -setsecurewebproxy \(service) \(host) \(port)"
        case let .setSecureWebProxyState(service, enabled):
            "networksetup -setsecurewebproxystate \(service) \(enabled ? "on" : "off")"
        case let .setBypassDomains(service, domains):
            domains.isEmpty
                ? "networksetup -setproxybypassdomains \(service) Empty"
                : "networksetup -setproxybypassdomains \(service) \(domains.joined(separator: " "))"
        }
    }
}

public struct SystemProxyPlan: Equatable, Sendable {
    public var commands: [SystemProxyCommand]
    public var recoveryCommands: [String]

    public init(commands: [SystemProxyCommand]) {
        self.commands = commands
        self.recoveryCommands = commands.map(\.networkSetupCommand)
    }
}

public enum SystemProxyPlanner {
    public static func enablePlan(
        from snapshot: SystemProxySnapshot,
        proxyHost: String,
        proxyPort: Int,
        bypassDomains: [String]
    ) -> SystemProxyPlan {
        SystemProxyPlan(commands: snapshot.services.flatMap { service -> [SystemProxyCommand] in
            guard service.isServiceEnabled else { return [] }
            return [
                .setSecureWebProxy(service: service.name, host: proxyHost, port: proxyPort),
                .setSecureWebProxyState(service: service.name, enabled: true),
                .setBypassDomains(service: service.name, domains: bypassDomains)
            ]
        })
    }

    public static func restorePlan(from snapshot: SystemProxySnapshot) -> SystemProxyPlan {
        SystemProxyPlan(commands: snapshot.services.flatMap(restoreCommands))
    }

    public static func rollbackPlan(
        afterFailedEnable _: SystemProxyPlan,
        originalSnapshot: SystemProxySnapshot,
        mutatedServices: [String]
    ) -> SystemProxyPlan {
        let mutated = Set(mutatedServices)
        return SystemProxyPlan(commands: originalSnapshot.services
            .filter { mutated.contains($0.name) }
            .flatMap(restoreCommands))
    }

    private static func restoreCommands(for service: SystemProxyServiceSnapshot) -> [SystemProxyCommand] {
        var commands: [SystemProxyCommand] = []
        if let host = service.secureWebProxy.host, let port = service.secureWebProxy.port {
            commands.append(.setSecureWebProxy(service: service.name, host: host, port: port))
        }
        commands.append(.setSecureWebProxyState(service: service.name, enabled: service.secureWebProxy.enabled))
        commands.append(.setBypassDomains(service: service.name, domains: service.bypassDomains))
        return commands
    }
}

public struct SystemProxyManager: Sendable {
    public init() {}
}
