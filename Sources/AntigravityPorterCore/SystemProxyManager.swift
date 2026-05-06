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

public struct AutoProxyState: Equatable, Codable, Sendable {
    public var enabled: Bool
    public var url: String?

    public init(enabled: Bool, url: String?) {
        self.enabled = enabled
        self.url = url
    }
}

public struct SystemProxyServiceSnapshot: Equatable, Codable, Sendable {
    public var name: String
    public var isServiceEnabled: Bool
    public var secureWebProxy: SecureWebProxyState
    public var autoProxy: AutoProxyState
    public var bypassDomains: [String]

    public init(
        name: String,
        isServiceEnabled: Bool,
        secureWebProxy: SecureWebProxyState,
        autoProxy: AutoProxyState = .init(enabled: false, url: nil),
        bypassDomains: [String]
    ) {
        self.name = name
        self.isServiceEnabled = isServiceEnabled
        self.secureWebProxy = secureWebProxy
        self.autoProxy = autoProxy
        self.bypassDomains = bypassDomains
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case isServiceEnabled
        case secureWebProxy
        case autoProxy
        case bypassDomains
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            isServiceEnabled: try container.decode(Bool.self, forKey: .isServiceEnabled),
            secureWebProxy: try container.decode(SecureWebProxyState.self, forKey: .secureWebProxy),
            autoProxy: try container.decodeIfPresent(AutoProxyState.self, forKey: .autoProxy) ?? .init(enabled: false, url: nil),
            bypassDomains: try container.decode([String].self, forKey: .bypassDomains)
        )
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
    case setAutoProxyURL(service: String, url: String)
    case setAutoProxyState(service: String, enabled: Bool)
    case setBypassDomains(service: String, domains: [String])

    public var serviceName: String {
        switch self {
        case let .setSecureWebProxy(service, _, _),
             let .setSecureWebProxyState(service, _),
             let .setAutoProxyURL(service, _),
             let .setAutoProxyState(service, _),
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
        case let .setAutoProxyURL(service, url):
            ["-setautoproxyurl", service, url]
        case let .setAutoProxyState(service, enabled):
            ["-setautoproxystate", service, enabled ? "on" : "off"]
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
        bypassDomains _: [String]
    ) -> SystemProxyPlan {
        let pacURL = "http://\(proxyHost):\(proxyPort)/proxy.pac"
        return SystemProxyPlan(commands: snapshot.services.flatMap { service -> [SystemProxyCommand] in
            guard service.isServiceEnabled else { return [] }
            return [
                .setAutoProxyURL(service: service.name, url: pacURL),
                .setAutoProxyState(service: service.name, enabled: true)
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
        if let url = service.autoProxy.url {
            commands.append(.setAutoProxyURL(service: service.name, url: url))
        }
        commands.append(.setAutoProxyState(service: service.name, enabled: service.autoProxy.enabled))
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

public enum NetworkSetupSnapshotParser {
    public enum ParseError: Error, Equatable, Sendable {
        case missingEnabled
        case invalidPort(String)
    }

    public static func parseSecureWebProxy(_ output: String) throws -> SecureWebProxyState {
        var enabled: Bool?
        var host: String?
        var port: Int?

        for line in normalizedLines(output) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "enabled":
                enabled = value.lowercased() == "yes"
            case "server":
                host = value.isEmpty ? nil : value
            case "port":
                if value.isEmpty || value == "0" {
                    port = nil
                } else if let parsed = Int(value) {
                    port = parsed
                } else {
                    throw ParseError.invalidPort(value)
                }
            default:
                continue
            }
        }

        guard let enabled else { throw ParseError.missingEnabled }
        return SecureWebProxyState(enabled: enabled, host: host, port: port)
    }

    public static func parseAutoProxyURL(_ output: String) throws -> AutoProxyState {
        var enabled: Bool?
        var url: String?

        for line in normalizedLines(output) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "enabled":
                enabled = value.lowercased() == "yes"
            case "url":
                url = value.isEmpty || value == "(null)" ? nil : value
            default:
                continue
            }
        }

        guard let enabled else { throw ParseError.missingEnabled }
        return AutoProxyState(enabled: enabled, url: url)
    }

    public static func parseBypassDomains(_ output: String) -> [String] {
        let lines = normalizedLines(output)
        guard !lines.contains(where: { $0.lowercased().contains("there aren't any bypass domains") }) else {
            return []
        }
        return lines.filter { !$0.isEmpty }
    }

    public static func parseNetworkServices(_ output: String) -> [SystemProxyServiceIdentity] {
        normalizedLines(output).dropFirst().compactMap { line in
            let isEnabled = !line.hasPrefix("*")
            let name = isEnabled ? line : String(line.dropFirst())
            return name.isEmpty ? nil : SystemProxyServiceIdentity(name: name, isServiceEnabled: isEnabled)
        }
    }

    private static func normalizedLines(_ output: String) -> [String] {
        output
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public struct SystemProxyServiceIdentity: Equatable, Sendable {
    public var name: String
    public var isServiceEnabled: Bool

    public init(name: String, isServiceEnabled: Bool) {
        self.name = name
        self.isServiceEnabled = isServiceEnabled
    }
}

public protocol SystemProxySnapshotReading: Sendable {
    func currentSnapshot() throws -> SystemProxySnapshot
}

public struct NetworkSetupSnapshotReader: SystemProxySnapshotReading {
    public init() {}

    public func currentSnapshot() throws -> SystemProxySnapshot {
        let identities = NetworkSetupSnapshotParser.parseNetworkServices(try run(arguments: ["-listallnetworkservices"]))
        let services = try identities.map { identity in
            SystemProxyServiceSnapshot(
                name: identity.name,
                isServiceEnabled: identity.isServiceEnabled,
                secureWebProxy: try NetworkSetupSnapshotParser.parseSecureWebProxy(
                    try run(arguments: ["-getsecurewebproxy", identity.name])
                ),
                autoProxy: try NetworkSetupSnapshotParser.parseAutoProxyURL(
                    try run(arguments: ["-getautoproxyurl", identity.name])
                ),
                bypassDomains: NetworkSetupSnapshotParser.parseBypassDomains(
                    try run(arguments: ["-getproxybypassdomains", identity.name], allowFailure: true)
                )
            )
        }
        return SystemProxySnapshot(id: UUID().uuidString, services: services, createdAt: Date())
    }

    private func run(arguments: [String], allowFailure: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let error = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if process.terminationStatus != 0, !allowFailure {
            throw SystemProxyManagerError.networkSetupQueryFailed(arguments: arguments, status: process.terminationStatus, stderr: error)
        }
        return output.isEmpty ? error : output
    }
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
    case networkSetupQueryFailed(arguments: [String], status: Int32, stderr: String)
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
                case let .networkSetupQueryFailed(arguments, status, stderr):
                    failure = .commandFailed(command: .setSecureWebProxyState(service: arguments.joined(separator: " "), enabled: false), status: status, stderr: stderr)
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
