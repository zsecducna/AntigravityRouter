import Darwin
import Foundation
import XCTest

final class NetworkFrameworkRuntimeBlackBoxTests: XCTestCase {
    func testMonitorCheckModeStartsBoundedNetworkFrameworkListeners() throws {
        let executable = try monitorExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--check", "--port", "0", "--json-log"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                if !process.waitUntilExit(timeout: 5) {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }

        let line = try readLine(from: output.fileHandleForReading, timeout: 5)
        XCTAssertTrue(line.contains("\"event\":\"ready\""), line)
        let ports = parsePorts(from: line)
        let ipv4Port = try XCTUnwrap(ports["ipv4_port"])
        XCTAssertGreaterThan(ipv4Port, 0)
        XCTAssertTrue(canConnect(host: "127.0.0.1", port: ipv4Port))
        if let ipv6Port = ports["ipv6_port"], ipv6Port > 0 {
            XCTAssertTrue(canConnect(host: "::1", port: ipv6Port))
        }
    }

    func testMonitorHelpIsBounded() throws {
        let executable = try monitorExecutable()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["--help"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertTrue(text.contains("usage: AntigravityPorterMonitor"))
    }

    private func monitorExecutable() throws -> String {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent(".build/debug/AntigravityPorterMonitor").path,
            cwd.appendingPathComponent(".build/arm64-apple-macosx/debug/AntigravityPorterMonitor").path,
            cwd.appendingPathComponent(".build/x86_64-apple-macosx/debug/AntigravityPorterMonitor").path
        ]
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        build.arguments = ["swift", "build", "--product", "AntigravityPorterMonitor"]
        try build.run()
        build.waitUntilExit()
        if let existing = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return existing
        }
        throw XCTSkip("AntigravityPorterMonitor executable not found after build")
    }

    private func readLine(from handle: FileHandle, timeout: TimeInterval) throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        while Date() < deadline {
            let chunk = handle.availableData
            if chunk.isEmpty { continue }
            data.append(chunk)
            if data.contains(0x0a) {
                break
            }
        }
        guard let text = String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)
        else {
            throw XCTSkip("No readiness line emitted")
        }
        return text
    }

    private func parsePorts(from line: String) -> [String: Int] {
        var ports: [String: Int] = [:]
        for key in ["ipv4_port", "ipv6_port"] {
            guard let range = line.range(of: "\"\(key)\":") else { continue }
            let suffix = line[range.upperBound...]
            let digits = suffix.prefix { $0.isNumber }
            ports[key] = Int(digits)
        }
        return ports
    }

    private func canConnect(host: String, port: Int) -> Bool {
        let fd = socket(host == "::1" ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if host == "::1" {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = in_port_t(port).bigEndian
            inet_pton(AF_INET6, host, &address.sin6_addr)
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0
                }
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        inet_pton(AF_INET, host, &address.sin_addr)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

private extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if isRunning {
            return false
        }
        return true
    }
}
