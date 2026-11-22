import Foundation

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
}
func until(_ message: String, _ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !predicate(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    check(predicate(), message)
}
func pair() -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    check(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0, "socketpair")
    return (fds[0], fds[1])
}
func connectPhone() -> Int32 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = Wire.devicePort.bigEndian
    address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    check(result == 0, "connect listener")
    return fd
}

// Real transport: repeated start/close must produce one close and release the fd,
// including connections rejected before start. Queued commands must die on close.
for index in 0..<100 {
    let (fd, peer) = pair()
    let connection = WireConnection(fd: fd)
    var closes = 0
    var messages = 0
    connection.onClose = { closes += 1 }
    connection.onMessage = { _, _ in messages += 1 }
    if index % 2 == 0 { connection.start(); connection.start() }
    let packet: [UInt8] = [MessageType.setCamera.rawValue, 0, 0, 0, 1, 1]
    _ = packet.withUnsafeBytes { write(peer, $0.baseAddress!, $0.count) }
    connection.close()
    connection.close()
    until("exactly one close") { closes == 1 }
    check(messages == 0, "closed session delivered a queued command")
    check(!connection.send(.hello), "closed send accepted")
    check(fcntl(fd, F_GETFD) == -1, "descriptor leaked")
    Darwin.close(peer)
}
print("PASS: 100 transport close/start/stale-command cycles")

let server = PhoneServer()
var accepted: [WireConnection] = []
server.onConnection = { accepted.append($0); $0.start() }
for _ in 0..<20 {
    server.start()
    let peer = connectPhone()
    // No main queue delivery until after stop: this accept belongs to an old generation.
    server.stop()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    check(accepted.isEmpty, "stale accept survived stop")
    Darwin.close(peer)
}
server.start()
let peer = connectPhone()
until("listener failed to recover") { accepted.count == 1 }
accepted.removeFirst().close()
Darwin.close(peer)
server.stop()
print("PASS: 20 listener stop/restart cycles, stale accepts rejected, fresh connection delivered")

setenv("I7_DIRECT_PORT", String(Wire.devicePort), 1)
server.start()
server.onConnection = { connection in
    connection.start()
    accepted.append(connection)
}
let link = PhoneLink()
var connects = 0
var disconnects = 0
link.onConnected = { $0.start(); connects += 1 }
link.onDisconnected = { disconnects += 1 }
link.start()
until("initial direct connection") { connects == 1 && accepted.count == 1 }
accepted.removeFirst().close()
until("unplug disconnect") { disconnects == 1 }
until("unplug recovery") { connects == 2 && accepted.count == 1 }
link.setSuspended(true)
check(disconnects == 2, "sleep did not synchronously detach")
accepted.removeFirst().close()
link.setSuspended(false)
until("wake recovery") { connects == 3 && accepted.count == 1 }
link.setSuspended(true)
accepted.removeFirst().close()
server.stop()
print("PASS: PhoneLink unplug/reconnect and suspend/wake recovery over real loopback sockets")
