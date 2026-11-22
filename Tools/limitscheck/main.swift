import Foundation

let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }
let tool = directory.appendingPathComponent("CodexBarCLI")
func writeTool(_ body: String) {
    try! ("#!/bin/sh\n" + body + "\n").write(to: tool, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
}
// Fixed accounts and scratch storage keep the check away from the real CodexBar config and saved numbers.
let suite = "limitscheck." + UUID().uuidString
let storage = UserDefaults(suiteName: suite)!
defer { storage.removePersistentDomain(forName: suite) }
let picked = [DashboardAccount(provider: .claude, account: nil), DashboardAccount(provider: .codex, account: nil)]
let source = LimitsSource(tool: tool.path, accounts: { picked }, defaults: storage)
let received = DispatchSemaphore(value: 0)
var expectedState = UsageState.sourceMissing
var expectedCount = 0
source.onUpdate = { values, state in
    precondition(state == expectedState && values.count == expectedCount)
    // Every picked account keeps its card; with nothing loaded they are all "No data" placeholders.
    if state == .unavailable { precondition(values.allSatisfy { $0.unavailable == true }) }
    if state == .available { precondition(values.allSatisfy { $0.unavailable != true && $0.updatedAt != nil }) }
    received.signal()
}
func refresh(_ state: UsageState, count: Int) {
    expectedState = state
    expectedCount = count
    source.start()
    precondition(received.wait(timeout: .now() + 5) == .success)
    source.stop()
}
refresh(.sourceMissing, count: 0)
writeTool("exit 1")
refresh(.unavailable, count: 2)
writeTool("echo '{\"usage\":{\"primary\":{\"usedPercent\":12},\"secondary\":{\"usedPercent\":34}},\"daily\":[]}'")
refresh(.available, count: 2)
try FileManager.default.removeItem(at: tool)
refresh(.sourceMissing, count: 0) // Removal must discard the previous successful snapshot.
writeTool("exit 1")
refresh(.unavailable, count: 2) // Reinstall with no providers cannot resurrect old limits.
print("Limits source passed: missing, failure, available, removal clears cache, reinstall")
