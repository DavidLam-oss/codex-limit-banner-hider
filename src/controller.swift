import Foundation
import Darwin

private let appPath = "/Applications/ChatGPT.app"
private let executablePath = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
private let bundleID = "com.openai.codex"
private let teamID = "2DC432GLL2"
private let supportPath = NSString(string: "~/Library/Application Support/Codex Limit Banner Hider").expandingTildeInPath
private let codexProfileDirectory = NSString(string: "~/Library/Application Support/Codex").expandingTildeInPath
private let isSelfTestInvocation = CommandLine.arguments.dropFirst().first?.hasPrefix("self-test-") == true
private let stateDirectory = isSelfTestInvocation
    ? FileManager.default.temporaryDirectory.appendingPathComponent("codex-limit-banner-hider-state.\(getpid())").path
    : supportPath + "/state"
private let statusPath = stateDirectory + "/status.json"
private let runtimePath = stateDirectory + "/runtime.json"
private let injectionPath = supportPath + "/install/share/injected.js"
private let managedFlag = "--codex-limit-banner-hider-managed"
private let controllerVersion = "1.3.0"
private let freshLaunchAge: TimeInterval = 15
private let pendingLaunchLifetime: TimeInterval = 90

private func isoDate() -> String { ISO8601DateFormatter().string(from: Date()) }

private func shell(_ launchPath: String, _ arguments: [String]) -> (Int32, String) {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    } catch {
        return (127, String(describing: error))
    }
}

private func readJSON(_ path: String) -> [String: Any] {
    guard let data = FileManager.default.contents(atPath: path),
          let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return value
}

private func writeJSON(_ value: [String: Any], to path: String) {
    do {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let temporary = path + ".tmp." + String(getpid())
        try data.write(to: URL(fileURLWithPath: temporary), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        try FileManager.default.moveItem(atPath: temporary, toPath: path)
    } catch {
        fputs("status write failed: \(error)\n", stderr)
    }
}

private func updateStatus(_ fields: [String: Any]) {
    let previous = readJSON(statusPath)
    var status: [String: Any] = [
        "installed": true,
        "version": controllerVersion,
        "controllerVersion": controllerVersion,
        "controllerPID": Int(getpid()),
        "mode": "unknown",
        "decision": "unknown",
        "codexPID": NSNull(),
        "codexVersion": appVersion(),
        "signatureValid": NSNull(),
        "exactTitleCount": 0,
        "qualifiedCount": 0,
        "hiddenCount": 0,
        "mainTargetCount": 0,
        "injectionVersion": NSNull(),
        "pendingCandidatePID": NSNull(),
        "lastError": NSNull(),
    ]
    for (key, value) in fields { status[key] = value }
    var previousComparable = previous
    previousComparable.removeValue(forKey: "updatedAt")
    var nextComparable = status
    nextComparable.removeValue(forKey: "updatedAt")
    if NSDictionary(dictionary: previousComparable).isEqual(to: nextComparable) { return }
    status["updatedAt"] = isoDate()
    writeJSON(status, to: statusPath)

    let transitionKeys = ["mode", "decision", "codexPID", "pendingCandidatePID"]
    let transitioned = transitionKeys.contains { key in
        let before = previous[key] ?? NSNull()
        let after = status[key] ?? NSNull()
        return !NSDictionary(dictionary: ["value": before]).isEqual(to: ["value": after])
    }
    if transitioned,
       let data = try? JSONSerialization.data(withJSONObject: status, options: [.sortedKeys]),
       let line = String(data: data, encoding: .utf8) {
        print(line)
        fflush(stdout)
    }
}

private func validateApplication() -> (Bool, String) {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else { return (false, "Codex executable not found") }
    let requirement = "identifier \"\(bundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    let verification = shell("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=\(requirement)", appPath])
    if verification.0 != 0 { return (false, "OpenAI signature verification failed") }

    // Read Info.plist in-process. Launching PlistBuddy from the background
    // controller produced repeatable false mismatches even though codesign and
    // a direct plist read both reported the expected identifier.
    do {
        let plistData = try Data(contentsOf: URL(fileURLWithPath: appPath + "/Contents/Info.plist"))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let observedBundleID = plist["CFBundleIdentifier"] as? String else {
            return (false, "Bundle identifier could not be read")
        }
        guard observedBundleID == bundleID else {
            return (false, "Bundle identifier mismatch: expected \(bundleID), found \(observedBundleID)")
        }
    } catch {
        return (false, "Bundle identifier read failed: \(error.localizedDescription)")
    }
    return (true, "ok")
}

private var cachedVersionFingerprint = ""
private var cachedVersion = "unknown"

private func appVersion() -> String {
    let plistPath = appPath + "/Contents/Info.plist"
    let attributes = try? FileManager.default.attributesOfItem(atPath: plistPath)
    let modificationDate = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let fileSize = attributes?[.size] as? NSNumber ?? 0
    let fingerprint = "\(modificationDate):\(fileSize)"
    if fingerprint == cachedVersionFingerprint { return cachedVersion }
    let result = shell("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", plistPath])
    cachedVersion = result.0 == 0 ? result.1.trimmingCharacters(in: .whitespacesAndNewlines) : "unknown"
    cachedVersionFingerprint = fingerprint
    return cachedVersion
}

private struct AppProcess {
    let pid: pid_t
    let age: TimeInterval
    let startedAt: TimeInterval
    let command: String

    var identity: String { "\(pid):\(Int64(startedAt))" }
}

private func findApplicationProcesses() -> [AppProcess] {
    // libproc identifies the exact executable without depending on ps output
    // width or argv formatting. ps is then scoped to the few exact PIDs only.
    let estimatedCount = max(Int(proc_listallpids(nil, 0)), 1)
    var pids = [pid_t](repeating: 0, count: estimatedCount + 64)
    let listedCount = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    guard listedCount > 0 else { return [] }

    return pids.prefix(min(listedCount, pids.count)).compactMap { pid in
        guard pid > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0, String(cString: path) == executablePath else { return nil }
        var info = proc_bsdinfo()
        let infoSize = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(MemoryLayout<proc_bsdinfo>.size))
        }
        guard infoSize == MemoryLayout<proc_bsdinfo>.size, info.pbi_start_tvsec > 0 else { return nil }
        let startedAt = TimeInterval(info.pbi_start_tvsec)
        let age = max(0, Date().timeIntervalSince1970 - startedAt)
        return AppProcess(pid: pid, age: age, startedAt: startedAt, command: executablePath)
    }.sorted { $0.age < $1.age }
}

private func readCommandLine(pid: pid_t) -> String? {
    // Read argv natively via KERN_PROCARGS2 instead of forking /bin/ps once
    // per candidate per polling cycle.
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    if sysctl(&mib, 3, nil, &size, nil, 0) != 0 { return nil }
    guard size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var argc: Int32 = 0
    memcpy(&argc, buffer, MemoryLayout<Int32>.size)
    guard argc > 0 else { return nil }
    var index = MemoryLayout<Int32>.size
    while index < size && buffer[index] != 0 { index += 1 } // executable path
    var arguments: [String] = []
    while index < size && arguments.count < Int(argc) {
        while index < size && buffer[index] == 0 { index += 1 }
        let start = index
        while index < size && buffer[index] != 0 { index += 1 }
        if index > start { arguments.append(String(bytes: buffer[start..<index], encoding: .utf8) ?? "") }
    }
    guard !arguments.isEmpty else { return nil }
    return arguments.joined(separator: " ")
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

// CDP over a localhost WebSocket. The managed app is launched through Launch
// Services with --remote-debugging-port=0, so Chromium picks a random port and
// records it plus the browser-level WebSocket path in <profile>/DevToolsActivePort.
private final class CDPClient {
    private let lock = NSLock()
    private var nextID = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        session = URLSession(configuration: .ephemeral)
        task = session.webSocketTask(with: url)
        task.resume()
        receiveNext()
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                if case .string(let text) = message { self.consume(text) }
                self.receiveNext()
            case .failure:
                break // connection closed; outstanding commands hit their timeout
            }
        }
    }

    private func consume(_ text: String) {
        guard let data = text.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = message["id"] as? Int else { return }
        lock.lock()
        let callback = pending.removeValue(forKey: id)
        lock.unlock()
        callback?(message)
    }

    func command(_ method: String, params: [String: Any] = [:], sessionID: String? = nil, timeout: TimeInterval = 8) -> [String: Any]? {
        let semaphore = DispatchSemaphore(value: 0)
        var response: [String: Any]?
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = { value in response = value; semaphore.signal() }
        lock.unlock()

        var message: [String: Any] = ["id": id, "method": method, "params": params]
        if let sessionID { message["sessionId"] = sessionID }
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let text = String(data: data, encoding: .utf8) else {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }
        task.send(.string(text)) { _ in }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }
        return response
    }

    func close() { task.cancel(with: .goingAway, reason: nil) }
    deinit { close() }
}

private struct ManagedApplication { let pid: pid_t; let cdp: CDPClient }

// `open --args` does not deliver command-line arguments to ChatGPT.app on this
// macOS (activation-style launching swallows them), but Launch Services still
// gives the app its normal foreground context — which direct posix_spawn
// lacks and which showed up as input lag. The shim bridges the gap: a tiny
// locally generated .app bundle is launched through Launch Services, and its
// launcher execs the real (signature-verified) Codex binary with the
// debugging flags baked in. The exec keeps the LS-launched process context
// while restoring full argv.
private func shimBundlePath() -> String { supportPath + "/install/shim/CodexDebugShim.app" }

private func writeShimBundle(launchArguments: [String]) -> Bool {
    let bundle = shimBundlePath()
    let contentsDirectory = bundle + "/Contents"
    let macosDirectory = contentsDirectory + "/MacOS"
    try? FileManager.default.removeItem(atPath: bundle)
    guard (try? FileManager.default.createDirectory(atPath: macosDirectory, withIntermediateDirectories: true)) != nil else { return false }
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.codex-limit-banner-hider.debugshim</string>
    <key>CFBundleName</key><string>CodexDebugShim</string>
    <key>CFBundleExecutable</key><string>launcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>LSUIElement</key><true/>
    </dict></plist>
    """
    guard (try? plist.write(toFile: contentsDirectory + "/Info.plist", atomically: true, encoding: .utf8)) != nil else { return false }
    let arguments = (["--remote-debugging-port=0", managedFlag] + launchArguments)
        .map { $0.contains("'") ? "''" : $0 }
        .map { "'\($0)'" }
        .joined(separator: " ")
    let launcher = """
    #!/bin/zsh
    export __CFBundleIdentifier='\(bundleID)'
    exec '\(executablePath)' \(arguments)
    """
    do {
        try launcher.write(toFile: macosDirectory + "/launcher", atomically: true, encoding: .utf8)
    } catch { return false }
    do {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: macosDirectory + "/launcher")
    } catch { return false }
    return true
}

private func launchManagedApplication(profileDirectory: String, launchArguments: [String] = []) -> ManagedApplication? {
    let launchTime = Date()
    guard writeShimBundle(launchArguments: launchArguments) else { return nil }
    let openResult = shell("/usr/bin/open", ["-n", shimBundlePath()])
    guard openResult.0 == 0 else { return nil }

    let portFilePath = profileDirectory + "/DevToolsActivePort"
    let deadline = launchTime.addingTimeInterval(30)
    while Date() < deadline {
        if let content = try? String(contentsOfFile: portFilePath, encoding: .utf8) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: portFilePath)
            let modified = (attributes?[.modificationDate] as? Date) ?? .distantPast
            let lines = content.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            if modified >= launchTime.addingTimeInterval(-2), lines.count >= 2,
               let port = UInt16(lines[0]), port != 0,
               let url = URL(string: "ws://127.0.0.1:\(port)\(lines[1])") {
                let cdp = CDPClient(url: url)
                if cdp.command("Browser.getVersion", timeout: 5) != nil {
                    // The exec'd binary replaces the launcher script process,
                    // so it keeps the LS-launched PID. Identify it by the
                    // managed flag in its command line.
                    var foundPID: pid_t?
                    let pidDeadline = Date().addingTimeInterval(15)
                    while foundPID == nil && Date() < pidDeadline {
                        foundPID = findApplicationProcesses().first { process in
                            process.startedAt >= launchTime.timeIntervalSince1970 - 1 &&
                            (readCommandLine(pid: process.pid)?.contains(managedFlag) ?? false)
                        }?.pid
                        if foundPID == nil { usleep(300_000) }
                    }
                    guard let pid = foundPID else {
                        cdp.close()
                        return nil
                    }
                    return ManagedApplication(pid: pid, cdp: cdp)
                }
                cdp.close()
            }
        }
        usleep(500_000)
    }
    return nil
}

private func launchOrdinaryApplication() -> pid_t? {
    let before = Set(findApplicationProcesses().map(\.pid))
    let openResult = shell("/usr/bin/open", ["-n", appPath])
    guard openResult.0 == 0 else { return nil }
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if let fresh = findApplicationProcesses().first(where: { !before.contains($0.pid) }) {
            return fresh.pid
        }
        usleep(300_000)
    }
    return nil
}

private func preserveOrdinaryApplication(reason: String) {
    var runtime = readJSON(runtimePath)
    guard let pid = launchOrdinaryApplication() else {
        runtime.removeValue(forKey: "managedPID")
        runtime.removeValue(forKey: "managedStartedAt")
        runtime.removeValue(forKey: "managedProcessStartedAt")
        writeJSON(runtime, to: runtimePath)
        updateStatus(["mode": "degraded", "decision": "ordinary-relaunch-failed", "lastError": reason])
        return
    }
    runtime.removeValue(forKey: "managedPID")
    runtime.removeValue(forKey: "managedStartedAt")
    runtime.removeValue(forKey: "managedProcessStartedAt")
    runtime["skipPID"] = Int(pid)
    runtime["skipDecision"] = "ordinary-codex-restored"
    runtime["skipSignatureValid"] = true
    runtime["skipLastError"] = reason
    writeJSON(runtime, to: runtimePath)
    updateStatus(["mode": "deferred", "codexPID": Int(pid), "decision": "ordinary-codex-restored", "lastError": reason])
}

private func childIsRunning(_ pid: pid_t) -> Bool {
    var status: Int32 = 0
    let result = waitpid(pid, &status, WNOHANG)
    if result == 0 { return true }
    if result == pid { return false }
    return isAlive(pid)
}

private func inject(into cdp: CDPClient, source: String, sessions: inout [String: String], injectedSessions: inout Set<String>) -> [String: Any] {
    guard let targetResponse = cdp.command("Target.getTargets"),
          let result = targetResponse["result"] as? [String: Any],
          let targets = result["targetInfos"] as? [[String: Any]] else {
        return ["decision": "cdp-unavailable"]
    }
    let mainTargets = targets.filter { ($0["type"] as? String) == "page" && ($0["url"] as? String) == "app://-/index.html" }
    guard mainTargets.count == 1, let targetID = mainTargets[0]["targetId"] as? String else {
        return ["decision": mainTargets.count > 1 ? "target-ambiguous" : "target-waiting", "mainTargetCount": mainTargets.count]
    }

    var sessionID = sessions[targetID]
    if sessionID == nil {
        guard let attached = cdp.command("Target.attachToTarget", params: ["targetId": targetID, "flatten": true]),
              let attachResult = attached["result"] as? [String: Any],
              let newSession = attachResult["sessionId"] as? String else {
            return ["decision": "attach-failed", "mainTargetCount": 1]
        }
        sessionID = newSession
        sessions[targetID] = newSession
    }
    guard let sessionID else { return ["decision": "attach-failed"] }

    let identityExpression = "JSON.stringify({ok:location.href==='app://-/index.html'&&document.title==='ChatGPT'&&!!document.querySelector('#root [class~=\"electron:h-toolbar\"]'),readyState:document.readyState})"
    guard let identityResponse = cdp.command("Runtime.evaluate", params: ["expression": identityExpression, "returnByValue": true], sessionID: sessionID),
          let identityResult = identityResponse["result"] as? [String: Any],
          let remote = identityResult["result"] as? [String: Any],
          let json = remote["value"] as? String,
          let identityData = json.data(using: .utf8),
          let identity = try? JSONSerialization.jsonObject(with: identityData) as? [String: Any],
          identity["ok"] as? Bool == true else {
        return ["decision": "identity-waiting", "mainTargetCount": 1]
    }

    if !injectedSessions.contains(sessionID) {
        if cdp.command("Page.addScriptToEvaluateOnNewDocument", params: ["source": source], sessionID: sessionID) == nil {
            return ["decision": "preload-injection-failed"]
        }
        if cdp.command("Runtime.evaluate", params: ["expression": source], sessionID: sessionID) == nil {
            return ["decision": "runtime-injection-failed"]
        }
        injectedSessions.insert(sessionID)
    }
    usleep(100_000)
    let statusExpression = "JSON.stringify(globalThis.__codexLimitBannerHiderStatus ?? {decision:'status-missing'})"
    guard let response = cdp.command("Runtime.evaluate", params: ["expression": statusExpression, "returnByValue": true], sessionID: sessionID),
          let responseResult = response["result"] as? [String: Any],
          let resultValue = responseResult["result"] as? [String: Any],
          let statusJSON = resultValue["value"] as? String,
          let data = statusJSON.data(using: .utf8),
          var status = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return ["decision": "status-unavailable"]
    }
    status["mainTargetCount"] = 1
    return status
}

// Decisions that mean the page is injected and verified. Once reached, the
// controller detaches from every CDP session and stays silent: no target
// discovery events, no periodic Runtime.evaluate pokes into the renderer main
// thread, no status churn. The injected script is self-sufficient from here on.
private let injectionCompleteDecisions: Set<String> = ["absent", "hidden", "ambiguous", "structure-rejected"]

private func terminateAndWait(_ pid: pid_t) {
    kill(pid, SIGTERM)
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        var status: Int32 = 0
        let waited = waitpid(pid, &status, WNOHANG)
        if waited == pid { return }                                          // child exited and reaped
        if waited == 0, isAlive(pid) { usleep(100_000); continue }           // child still running
        if waited < 0, errno == ECHILD, isAlive(pid) { usleep(100_000); continue } // not our child, alive
        if waited < 0, errno == EINTR { usleep(100_000); continue }
        return
    }
}

private func superviseManagedApplication(_ app: ManagedApplication, sourcePath: String = injectionPath, terminateAfterTest: Bool = false) {
    let source: String
    do { source = try String(contentsOfFile: sourcePath, encoding: .utf8) }
    catch {
        var runtime = readJSON(runtimePath)
        runtime.removeValue(forKey: "managedPID")
        runtime.removeValue(forKey: "managedStartedAt")
        runtime.removeValue(forKey: "managedProcessStartedAt")
        runtime["skipPID"] = Int(app.pid)
        runtime["skipDecision"] = "injection-file-missing-process-preserved"
        runtime["skipSignatureValid"] = true
        runtime["skipLastError"] = String(describing: error)
        writeJSON(runtime, to: runtimePath)
        updateStatus(["mode": "deferred", "codexPID": Int(app.pid), "decision": "injection-file-missing-process-preserved", "lastError": String(describing: error)])
        if terminateAfterTest { kill(app.pid, SIGTERM) }
        return
    }

    var runtime = readJSON(runtimePath)
    runtime["managedPID"] = Int(app.pid)
    runtime["managedStartedAt"] = isoDate()
    if let managedProcess = findApplicationProcesses().first(where: { $0.pid == app.pid }) {
        runtime["managedProcessStartedAt"] = managedProcess.startedAt
    }
    clearPreservedProcess(&runtime)
    writeJSON(runtime, to: runtimePath)
    updateStatus(["mode": "managed", "codexPID": Int(app.pid), "codexVersion": appVersion(), "decision": "starting", "signatureValid": true])

    _ = app.cdp.command("Browser.getVersion", timeout: 15)
    _ = app.cdp.command("Target.setDiscoverTargets", params: ["discover": true])
    var sessions: [String: String] = [:]
    var injectedSessions: Set<String> = []
    var detached = false
    let testDeadline = terminateAfterTest ? Date().addingTimeInterval(45) : nil
    while childIsRunning(app.pid) {
        if !detached {
            let injectionStatus = inject(into: app.cdp, source: source, sessions: &sessions, injectedSessions: &injectedSessions)
            var fields = injectionStatus
            if let injectionVersion = fields.removeValue(forKey: "version") {
                fields["injectionVersion"] = injectionVersion
            }
            fields["mode"] = "managed"
            fields["codexPID"] = Int(app.pid)
            fields["codexVersion"] = appVersion()
            fields["signatureValid"] = true
            updateStatus(fields)
            let decision = injectionStatus["decision"] as? String ?? "unknown"

            if injectionCompleteDecisions.contains(decision) {
                // Ephemeral CDP handoff: stop target discovery, detach every
                // session, and disconnect. A persistent attached DevTools
                // client measurably changes renderer behavior (timer
                // throttling, back/forward cache, network stack), which showed
                // up as input and session-switching lag in live use. The
                // injected script is self-sufficient from here on.
                _ = app.cdp.command("Target.setDiscoverTargets", params: ["discover": false])
                for (_, sessionID) in sessions {
                    _ = app.cdp.command("Target.detachFromTarget", params: ["sessionId": sessionID])
                }
                sessions.removeAll()
                injectedSessions.removeAll()
                app.cdp.close()
                detached = true
                updateStatus([
                    "mode": "managed",
                    "codexPID": Int(app.pid),
                    "decision": decision,
                    "supervision": "detached",
                    "signatureValid": true,
                ])
            }

            if terminateAfterTest,
               !["starting", "target-waiting", "identity-waiting"].contains(decision) {
                terminateAndWait(app.pid)
                break
            }
            if let testDeadline, Date() >= testDeadline {
                updateStatus(["mode": "degraded", "decision": "self-test-timeout", "codexPID": Int(app.pid)])
                terminateAndWait(app.pid)
                break
            }
            let needsFastRetry = ["starting", "target-waiting", "identity-waiting", "attach-failed", "status-unavailable"].contains(decision)
            sleep(needsFastRetry ? 1 : 10)
        } else {
            // Quiet supervision: no CDP traffic at all. Only wait for exit.
            sleep(10)
        }
    }
    runtime = readJSON(runtimePath)
    runtime.removeValue(forKey: "managedPID")
    runtime.removeValue(forKey: "managedStartedAt")
    runtime.removeValue(forKey: "managedProcessStartedAt")
    writeJSON(runtime, to: runtimePath)
    if !terminateAfterTest {
        updateStatus(["mode": "watching", "codexPID": NSNull(), "decision": "waiting-for-next-launch"])
    }
}

private func commandIsExternallyControlled(_ command: String) -> Bool {
    command.contains("--user-data-dir") || command.contains("--remote-debugging") || command.contains(managedFlag)
}

private func processStored(in runtime: [String: Any], pidKey: String, startedAtKey: String, processes: [AppProcess]) -> AppProcess? {
    guard let storedPID = runtime[pidKey] as? Int else { return nil }
    let matchingPID = processes.first { Int($0.pid) == storedPID }
    guard let process = matchingPID else { return nil }
    guard let storedStart = runtime[startedAtKey] as? Double else { return process }
    return abs(process.startedAt - storedStart) < 1 ? process : nil
}

private func clearPreservedProcess(_ runtime: inout [String: Any]) {
    runtime.removeValue(forKey: "skipPID")
    runtime.removeValue(forKey: "skipStartedAt")
    runtime.removeValue(forKey: "skipDecision")
    runtime.removeValue(forKey: "skipSignatureValid")
    runtime.removeValue(forKey: "skipLastError")
}

private func preserve(_ process: AppProcess, decision: String, signatureValid: Bool = true, lastError: String? = nil, runtime: inout [String: Any]) {
    runtime["skipPID"] = Int(process.pid)
    runtime["skipStartedAt"] = process.startedAt
    runtime["skipDecision"] = decision
    runtime["skipSignatureValid"] = signatureValid
    if let lastError {
        runtime["skipLastError"] = lastError
    } else {
        runtime.removeValue(forKey: "skipLastError")
    }
    writeJSON(runtime, to: runtimePath)
}

private func supervise() {
    updateStatus(["mode": "watching", "decision": "initializing", "signatureValid": NSNull()])
    var firstSeenFreshProcess: [String: Date] = [:]

    while true {
        var runtime = readJSON(runtimePath)
        let processes = findApplicationProcesses()

        let liveIdentities = Set(processes.map(\.identity))
        firstSeenFreshProcess = firstSeenFreshProcess.filter { liveIdentities.contains($0.key) }
        var commandByIdentity: [String: String] = [:]
        for process in processes {
            let command = readCommandLine(pid: process.pid) ?? process.command
            commandByIdentity[process.identity] = command
            if process.age <= freshLaunchAge, !commandIsExternallyControlled(command), firstSeenFreshProcess[process.identity] == nil {
                firstSeenFreshProcess[process.identity] = Date()
            }
        }

        let preserved = processStored(in: runtime, pidKey: "skipPID", startedAtKey: "skipStartedAt", processes: processes)
        if runtime["skipPID"] != nil, preserved == nil {
            clearPreservedProcess(&runtime)
            writeJSON(runtime, to: runtimePath)
        } else if let preserved, runtime["skipStartedAt"] == nil {
            runtime["skipStartedAt"] = preserved.startedAt
            runtime["skipDecision"] = runtime["skipDecision"] ?? "current-process-preserved"
            runtime["skipSignatureValid"] = runtime["skipSignatureValid"] ?? true
            writeJSON(runtime, to: runtimePath)
        }

        if let preserved {
            let pending = processes.first { process in
                process.identity != preserved.identity &&
                firstSeenFreshProcess[process.identity] != nil &&
                !commandIsExternallyControlled(commandByIdentity[process.identity] ?? process.command)
            }
            let preservedLastError: Any = (runtime["skipLastError"] as? String).map { $0 as Any } ?? NSNull()
            updateStatus([
                "mode": "deferred",
                "codexPID": Int(preserved.pid),
                "decision": runtime["skipDecision"] as? String ?? "current-process-preserved",
                "pendingCandidatePID": pending.map { Int($0.pid) } as Any? ?? NSNull(),
                "signatureValid": runtime["skipSignatureValid"] as? Bool ?? true,
                "lastError": preservedLastError,
            ])
            sleep(1)
            continue
        }

        if let managed = processStored(in: runtime, pidKey: "managedPID", startedAtKey: "managedProcessStartedAt", processes: processes) {
            updateStatus(["mode": "deferred", "codexPID": Int(managed.pid), "decision": "orphaned-managed-process-preserved", "signatureValid": true])
            sleep(1)
            continue
        } else if runtime["managedPID"] != nil {
            runtime.removeValue(forKey: "managedPID")
            runtime.removeValue(forKey: "managedStartedAt")
            runtime.removeValue(forKey: "managedProcessStartedAt")
            writeJSON(runtime, to: runtimePath)
        }

        let ordinaryProcesses = processes.filter { process in
            !commandIsExternallyControlled(commandByIdentity[process.identity] ?? process.command)
        }
        let now = Date()
        let candidate = ordinaryProcesses.first { process in
            guard let firstSeen = firstSeenFreshProcess[process.identity] else { return false }
            return now.timeIntervalSince(firstSeen) <= pendingLaunchLifetime
        }

        guard let candidate else {
            if let existing = ordinaryProcesses.first {
                preserve(existing, decision: "late-process-preserved", runtime: &runtime)
                updateStatus(["mode": "deferred", "codexPID": Int(existing.pid), "decision": "late-process-preserved", "signatureValid": true])
            } else if let external = processes.first {
                updateStatus(["mode": "deferred", "codexPID": Int(external.pid), "decision": "external-debug-process-preserved", "signatureValid": true])
            } else {
                updateStatus(["mode": "watching", "decision": "waiting-for-next-launch", "signatureValid": true])
            }
            sleep(1)
            continue
        }

        // Full deep signature verification is intentionally done only for a new,
        // freshly observed handoff candidate. Verification time does not consume
        // the launch window; identity is rechecked by PID and process start time.
        updateStatus(["mode": "handoff", "codexPID": Int(candidate.pid), "decision": "verifying-new-process", "signatureValid": NSNull()])
        let validation = validateApplication()
        guard validation.0 else {
            preserve(candidate, decision: "application-rejected-process-preserved", signatureValid: false, lastError: validation.1, runtime: &runtime)
            updateStatus(["mode": "deferred", "codexPID": Int(candidate.pid), "decision": "application-rejected-process-preserved", "signatureValid": false, "lastError": validation.1])
            continue
        }
        guard let refreshed = findApplicationProcesses().first(where: { $0.identity == candidate.identity }) else {
            updateStatus(["mode": "watching", "decision": "candidate-exited-during-verification", "signatureValid": true])
            continue
        }

        updateStatus(["mode": "handoff", "codexPID": Int(refreshed.pid), "decision": "restarting-new-process", "signatureValid": true])
        terminateAndWait(refreshed.pid)
        guard !isAlive(refreshed.pid) else {
            preserve(refreshed, decision: "graceful-handoff-failed-process-preserved", runtime: &runtime)
            updateStatus(["mode": "deferred", "codexPID": Int(refreshed.pid), "decision": "graceful-handoff-failed-process-preserved", "signatureValid": true])
            continue
        }
        usleep(300_000)
        guard let managed = launchManagedApplication(profileDirectory: codexProfileDirectory) else {
            preserveOrdinaryApplication(reason: "Could not launch signed Codex with a local debugging port")
            continue
        }
        superviseManagedApplication(managed)    }
}

private func printStatus(json: Bool) {
    let status = readJSON(statusPath)
    if json {
        if let data = try? JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys]) {
            print(String(data: data, encoding: .utf8) ?? "{}")
        }
        return
    }
    let installed = status["installed"] as? Bool == true ? "yes" : "no"
    print("Installed: \(installed)")
    print("Mode: \(status["mode"] ?? "unknown")")
    print("Decision: \(status["decision"] ?? "unknown")")
    print("Codex version: \(status["codexVersion"] ?? "unknown")")
    print("Codex PID: \(status["codexPID"] ?? "none")")
    print("Hidden banners: \(status["hiddenCount"] ?? 0)")
    print("Updated: \(status["updatedAt"] ?? "unknown")")
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first ?? "status" {
case "supervise": supervise()
case "self-test-processes":
    let processes = findApplicationProcesses().map { ["pid": Int($0.pid), "ageSeconds": $0.age, "command": $0.command] as [String: Any] }
    let data = try! JSONSerialization.data(withJSONObject: processes, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
case "self-test-application-validation":
    let validation = validateApplication()
    let result: [String: Any] = ["valid": validation.0, "message": validation.1]
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    if !validation.0 { exit(1) }
case "self-test-port":
    let testProfile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-limit-banner-hider-test.\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: testProfile, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(atPath: testProfile)
        try? FileManager.default.removeItem(atPath: stateDirectory)
    }
    guard arguments.count == 2,
          let managed = launchManagedApplication(profileDirectory: testProfile, launchArguments: ["--user-data-dir=\(testProfile)", "--no-first-run"]) else { exit(1) }
    superviseManagedApplication(managed, sourcePath: arguments[1], terminateAfterTest: true)
    printStatus(json: true)
case "status": printStatus(json: arguments.contains("--json"))
default:
    fputs("Usage: codex-limit-banner-hider-controller [supervise|status [--json]|self-test-port <injected.js>|self-test-processes|self-test-application-validation]\n", stderr)
    exit(64)
}
