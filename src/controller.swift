import Foundation
import Darwin

@_silgen_name("_NSGetEnviron")
private func NSGetEnviron() -> UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>

private let appPath = "/Applications/ChatGPT.app"
private let executablePath = "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
private let bundleID = "com.openai.codex"
private let teamID = "2DC432GLL2"
private let supportPath = NSString(string: "~/Library/Application Support/Codex Limit Banner Hider").expandingTildeInPath
private let isSelfTestInvocation = CommandLine.arguments.dropFirst().first == "self-test-pipe"
private let stateDirectory = isSelfTestInvocation
    ? FileManager.default.temporaryDirectory.appendingPathComponent("codex-limit-banner-hider-state.\(getpid())").path
    : supportPath + "/state"
private let statusPath = stateDirectory + "/status.json"
private let runtimePath = stateDirectory + "/runtime.json"
private let injectionPath = supportPath + "/install/share/injected.js"
private let managedFlag = "--codex-limit-banner-hider-managed"
private let controllerVersion = "1.1.0"
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
    let plist = shell("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleIdentifier", appPath + "/Contents/Info.plist"])
    if plist.0 != 0 || plist.1.trimmingCharacters(in: .whitespacesAndNewlines) != bundleID {
        return (false, "Bundle identifier mismatch")
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
    let result = shell("/bin/ps", ["-ww", "-p", String(pid), "-o", "command="])
    guard result.0 == 0 else { return nil }
    let command = result.1.trimmingCharacters(in: .whitespacesAndNewlines)
    return command.isEmpty ? nil : command
}

private func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

private final class CDPClient {
    private let input: FileHandle
    private let output: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var nextID = 1
    private var pending: [Int: ([String: Any]) -> Void] = [:]

    init(inputFD: Int32, outputFD: Int32) {
        input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: true)
        output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: true)
        output.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if !data.isEmpty { self?.consume(data) }
        }
    }

    deinit { output.readabilityHandler = nil }

    private func consume(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let end = buffer.firstIndex(of: 0) {
            let packet = buffer[..<end]
            buffer.removeSubrange(...end)
            guard !packet.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(packet)) as? [String: Any],
                  let id = message["id"] as? Int,
                  let callback = pending.removeValue(forKey: id) else { continue }
            lock.unlock()
            callback(message)
            lock.lock()
        }
        lock.unlock()
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
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return nil }
        data.append(0)
        do { try input.write(contentsOf: data) } catch { return nil }
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }
        return response
    }
}

private struct SpawnedApplication { let pid: pid_t; let cdp: CDPClient }

private func spawnManagedApplication(extraArguments: [String] = []) -> SpawnedApplication? {
    var toChild: [Int32] = [0, 0]
    var fromChild: [Int32] = [0, 0]
    guard pipe(&toChild) == 0 else { return nil }
    guard pipe(&fromChild) == 0 else {
        close(toChild[0]); close(toChild[1])
        return nil
    }

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addclose(&actions, toChild[1])
    posix_spawn_file_actions_addclose(&actions, fromChild[0])
    posix_spawn_file_actions_adddup2(&actions, toChild[0], 3)
    posix_spawn_file_actions_adddup2(&actions, fromChild[1], 4)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    if toChild[0] != 3 && toChild[0] != 4 { posix_spawn_file_actions_addclose(&actions, toChild[0]) }
    if fromChild[1] != 3 && fromChild[1] != 4 { posix_spawn_file_actions_addclose(&actions, fromChild[1]) }

    let args = [executablePath, "--remote-debugging-pipe", managedFlag] + extraArguments
    let argv = args.map { strdup($0) } + [nil]
    defer { argv.forEach { if let pointer = $0 { free(pointer) } } }
    var pid: pid_t = 0
    guard let environment = NSGetEnviron().pointee else { return nil }
    let result = posix_spawn(&pid, executablePath, &actions, nil, argv, environment)
    posix_spawn_file_actions_destroy(&actions)
    close(toChild[0]); close(fromChild[1])
    guard result == 0 else { close(toChild[1]); close(fromChild[0]); return nil }
    return SpawnedApplication(pid: pid, cdp: CDPClient(inputFD: toChild[1], outputFD: fromChild[0]))
}

private func spawnOrdinaryApplication() -> pid_t? {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
    let args = [executablePath]
    let argv = args.map { strdup($0) } + [nil]
    defer {
        argv.forEach { if let pointer = $0 { free(pointer) } }
        posix_spawn_file_actions_destroy(&actions)
    }
    guard let environment = NSGetEnviron().pointee else { return nil }
    var pid: pid_t = 0
    return posix_spawn(&pid, executablePath, &actions, nil, argv, environment) == 0 ? pid : nil
}

private func preserveOrdinaryApplication(reason: String) {
    var runtime = readJSON(runtimePath)
    guard let pid = spawnOrdinaryApplication() else {
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

    let identityExpression = "JSON.stringify({ok:location.href==='app://-/index.html'&&document.title==='ChatGPT'&&!!document.querySelector('#root')&&[...document.querySelectorAll('#root *')].some(e=>e.classList.contains('electron:h-toolbar')),readyState:document.readyState})"
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

private func superviseManagedApplication(_ app: SpawnedApplication, sourcePath: String = injectionPath, terminateAfterTest: Bool = false) {
    let source: String
    do { source = try String(contentsOfFile: sourcePath, encoding: .utf8) }
    catch {
        var runtime = readJSON(runtimePath)
        runtime.removeValue(forKey: "managedPID")
        runtime.removeValue(forKey: "managedStartedAt")
        runtime.removeValue(forKey: "managedProcessStartedAt")
        runtime["skipPID"] = Int(app.pid)
        runtime["skipDecision"] = "injection-file-missing-process-preserved"
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
    let testDeadline = terminateAfterTest ? Date().addingTimeInterval(45) : nil
    while childIsRunning(app.pid) {
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
        if terminateAfterTest,
           let decision = injectionStatus["decision"] as? String,
           !["starting", "target-waiting", "identity-waiting"].contains(decision) {
            kill(app.pid, SIGTERM)
        }
        if let testDeadline, Date() >= testDeadline {
            updateStatus(["mode": "degraded", "decision": "self-test-timeout", "codexPID": Int(app.pid)])
            kill(app.pid, SIGTERM)
        }
        sleep(3)
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
}

private func preserve(_ process: AppProcess, decision: String, runtime: inout [String: Any]) {
    runtime["skipPID"] = Int(process.pid)
    runtime["skipStartedAt"] = process.startedAt
    runtime["skipDecision"] = decision
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
            writeJSON(runtime, to: runtimePath)
        }

        if let preserved {
            let pending = processes.first { process in
                process.identity != preserved.identity &&
                firstSeenFreshProcess[process.identity] != nil &&
                !commandIsExternallyControlled(commandByIdentity[process.identity] ?? process.command)
            }
            updateStatus([
                "mode": "deferred",
                "codexPID": Int(preserved.pid),
                "decision": runtime["skipDecision"] as? String ?? "current-process-preserved",
                "pendingCandidatePID": pending.map { Int($0.pid) } as Any? ?? NSNull(),
                "signatureValid": true,
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
            preserve(candidate, decision: "application-rejected-process-preserved", runtime: &runtime)
            updateStatus(["mode": "deferred", "codexPID": Int(candidate.pid), "decision": "application-rejected-process-preserved", "signatureValid": false, "lastError": validation.1])
            continue
        }
        guard let refreshed = findApplicationProcesses().first(where: { $0.identity == candidate.identity }) else {
            updateStatus(["mode": "watching", "decision": "candidate-exited-during-verification", "signatureValid": true])
            continue
        }

        updateStatus(["mode": "handoff", "codexPID": Int(refreshed.pid), "decision": "restarting-new-process", "signatureValid": true])
        kill(refreshed.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(4)
        while isAlive(refreshed.pid) && Date() < deadline { usleep(100_000) }
        guard !isAlive(refreshed.pid) else {
            preserve(refreshed, decision: "graceful-handoff-failed-process-preserved", runtime: &runtime)
            updateStatus(["mode": "deferred", "codexPID": Int(refreshed.pid), "decision": "graceful-handoff-failed-process-preserved", "signatureValid": true])
            continue
        }
        usleep(300_000)
        guard let spawned = spawnManagedApplication() else {
            preserveOrdinaryApplication(reason: "Could not start signed Codex with private debugging pipe")
            continue
        }
        superviseManagedApplication(spawned)
    }
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
case "self-test-pipe":
    let testProfile = FileManager.default.temporaryDirectory.appendingPathComponent("codex-limit-banner-hider-test.\(UUID().uuidString)").path
    try? FileManager.default.createDirectory(atPath: testProfile, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(atPath: testProfile)
        try? FileManager.default.removeItem(atPath: stateDirectory)
    }
    guard arguments.count == 2, let spawned = spawnManagedApplication(extraArguments: ["--user-data-dir=\(testProfile)", "--no-first-run"]) else { exit(1) }
    superviseManagedApplication(spawned, sourcePath: arguments[1], terminateAfterTest: true)
    printStatus(json: true)
case "status": printStatus(json: arguments.contains("--json"))
default:
    fputs("Usage: codex-limit-banner-hider-controller [supervise|status [--json]]\n", stderr)
    exit(64)
}
