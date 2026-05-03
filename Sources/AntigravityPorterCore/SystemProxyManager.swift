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

    public var serviceName: String {
        switch self {
        case let .setSecureWebProxy(service, _, _),
             let .setSecureWebProxyState(service, _),
             let .setBypassDomains(service, _):
            service
        }
    }

    public var networkSetupArguments: [String] {
        switch self {
        case let .setSecureWebProxy(service, host, port):
            ["-setsecurewebproxy", service, host, String(port)]
        case let .setSecureWebProxyState(service, enabled):
            ["-setsecurewebproxystate", service, enabled ? "on" : "off"]
        case let .setBypassDomains(service, domains):
            domains.isEmpty
                ? ["-setproxybypassdomains", service, "Empty"]
                : ["-setproxybypassdomains", service] + domains
        }
    }

    public var networkSetupCommand: String {
        "networksetup " + networkSetupArguments.map(shellEscaped).joined(separator: " ")
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

public struct SystemProxyCommandResult: Equatable, Sendable {
    public var command: SystemProxyCommand
    public var standardOutput: String
    public var standardError: String

    public init(command: SystemProxyCommand, standardOutput: String = "", standardError: String = "") {
        self.command = command
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol SystemProxyCommandExecuting: Sendable {
    func run(_ command: SystemProxyCommand) throws -> SystemProxyCommandResult
}

public struct NetworkSetupCommandExecutor: SystemProxyCommandExecuting {
    public init() {}

    public func run(_ command: SystemProxyCommand) throws -> SystemProxyCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = command.networkSetupArguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw SystemProxyManagerError.commandFailed(command: command, status: process.terminationStatus, stderr: error)
        }
        return SystemProxyCommandResult(command: command, standardOutput: output, standardError: error)
    }
}

public struct SystemProxyRollbackReport: Equatable, Sendable {
    public var attempted: SystemProxyPlan
    public var results: [SystemProxyCommandResult]
    public var failure: SystemProxyRollbackFailure?

    public init(attempted: SystemProxyPlan, results: [SystemProxyCommandResult], failure: SystemProxyRollbackFailure? = nil) {
        self.attempted = attempted
        self.results = results
        self.failure = failure
    }
}

public enum SystemProxyRollbackFailure: Error, Equatable, Sendable {
    case commandFailed(command: SystemProxyCommand, status: Int32, stderr: String)
}

public enum SystemProxyManagerError: Error, Equatable, Sendable {
    case commandFailed(command: SystemProxyCommand, status: Int32, stderr: String)
    case enableFailed(command: SystemProxyCommand, appliedServices: [String], rollback: SystemProxyRollbackReport)
}

public struct SystemProxyManager: Sendable {
    private let executor: any SystemProxyCommandExecuting

    public init(executor: any SystemProxyCommandExecuting = NetworkSetupCommandExecutor()) {
        self.executor = executor
    }

    public func apply(_ plan: SystemProxyPlan) throws -> [SystemProxyCommandResult] {
        try plan.commands.map(executor.run)
    }

    public func enable(_ plan: SystemProxyPlan, originalSnapshot: SystemProxySnapshot) throws -> [SystemProxyCommandResult] {
        var results: [SystemProxyCommandResult] = []
        var mutatedServices: [String] = []

        for command in plan.commands {
            do {
                let result = try executor.run(command)
                results.append(result)
                if !mutatedServices.contains(command.serviceName) {
                    mutatedServices.append(command.serviceName)
                }
            } catch {
                let rollback = SystemProxyPlanner.rollbackPlan(
                    afterFailedEnable: plan,
                    originalSnapshot: originalSnapshot,
                    mutatedServices: mutatedServices
                )
                let rollbackReport = runRollback(rollback)
                throw SystemProxyManagerError.enableFailed(
                    command: command,
                    appliedServices: mutatedServices,
                    rollback: rollbackReport
                )
            }
        }

        return results
    }

    private func runRollback(_ plan: SystemProxyPlan) -> SystemProxyRollbackReport {
        var results: [SystemProxyCommandResult] = []
        for command in plan.commands {
            do {
                results.append(try executor.run(command))
            } catch let error as SystemProxyManagerError {
                let failure: SystemProxyRollbackFailure
                switch error {
                case let .commandFailed(command, status, stderr):
                    failure = .commandFailed(command: command, status: status, stderr: stderr)
                case let .enableFailed(command, _, _):
                    failure = .commandFailed(command: command, status: -1, stderr: String(describing: error))
                }
                return SystemProxyRollbackReport(attempted: plan, results: results, failure: failure)
            } catch {
                return SystemProxyRollbackReport(
                    attempted: plan,
                    results: results,
                    failure: .commandFailed(command: command, status: -1, stderr: String(describing: error))
                )
            }
        }
        return SystemProxyRollbackReport(attempted: plan, results: results)
    }
}

private func shellEscaped(_ value: String) -> String {
    guard !value.isEmpty else { return "''" }
    guard value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"$`\\!*?[]"))) != nil else {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
