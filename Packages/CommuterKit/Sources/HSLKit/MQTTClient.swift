import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct MQTTMessage: Sendable {
    public var topic: String
    public var payload: Data
}

/// Minimal MQTT 3.1.1 client (QoS 0, subscribe-only) over WebSocket.
/// That's all we need for HSL HFP (wss://mqtt.hsl.fi) and Digitraffic
/// (wss://rata.digitraffic.fi/mqtt), and it avoids third-party dependencies.
public actor MQTTClient {
    public enum State: Sendable { case disconnected, connecting, connected }

    private let url: URL
    private let clientId: String
    private let keepAlive: UInt16 = 60
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var buffer = Data()
    private var topics: Set<String> = []
    private var packetId: UInt16 = 1
    private var pingTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var reconnectDelay: TimeInterval = 1
    private var wantsConnection = false
    public private(set) var state: State = .disconnected

    private var continuation: AsyncStream<MQTTMessage>.Continuation?
    public nonisolated let messages: AsyncStream<MQTTMessage>

    public init(url: URL, clientId: String = "hslcommuter-\(UUID().uuidString.prefix(8))") {
        self.url = url
        self.clientId = clientId
        self.session = URLSession(configuration: .default)
        var cont: AsyncStream<MQTTMessage>.Continuation!
        self.messages = AsyncStream(bufferingPolicy: .bufferingNewest(500)) { cont = $0 }
        self.continuation = cont
    }

    public func connect() {
        wantsConnection = true
        guard state == .disconnected else { return }
        state = .connecting
        let task = session.webSocketTask(with: url, protocols: ["mqtt"])
        self.task = task
        buffer.removeAll()
        task.resume()
        send(Self.connectPacket(clientId: clientId, keepAlive: keepAlive))
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
    }

    public func disconnect() {
        wantsConnection = false
        if state == .connected { send(Data([0xE0, 0x00])) }
        teardown()
    }

    public func subscribe(_ topic: String) {
        guard topics.insert(topic).inserted else { return }
        if state == .connected { send(subscribePacket([topic])) }
    }

    public func unsubscribe(_ topic: String) {
        guard topics.remove(topic) != nil else { return }
        if state == .connected { send(unsubscribePacket([topic])) }
    }

    public func unsubscribeAll() {
        let all = Array(topics)
        topics.removeAll()
        if state == .connected, !all.isEmpty { send(unsubscribePacket(all)) }
    }

    // MARK: - Internals

    private func teardown() {
        pingTask?.cancel(); pingTask = nil
        receiveTask?.cancel(); receiveTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        state = .disconnected
    }

    private func scheduleReconnect() {
        teardown()
        guard wantsConnection else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            await self?.connect()
        }
    }

    private func send(_ data: Data) {
        task?.send(.data(data)) { _ in }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await task.receive()
                switch message {
                case .data(let d): handleIncoming(d)
                case .string(let s): handleIncoming(Data(s.utf8))
                @unknown default: break
                }
            } catch {
                if self.task === task { scheduleReconnect() }
                return
            }
        }
    }

    private func handleIncoming(_ data: Data) {
        buffer.append(data)
        while let packet = Self.parsePacket(buffer) {
            buffer = Data(buffer.dropFirst(packet.consumed))
            handlePacket(type: packet.type, flags: packet.flags, body: packet.body)
        }
    }

    private func handlePacket(type: UInt8, flags: UInt8, body: Data) {
        switch type {
        case 2: // CONNACK
            let rc = body.count >= 2 ? body[body.startIndex + 1] : 0xFF
            guard rc == 0 else { scheduleReconnect(); return }
            state = .connected
            reconnectDelay = 1
            if !topics.isEmpty { send(subscribePacket(Array(topics))) }
            startPinging()
        case 3: // PUBLISH
            guard body.count >= 2 else { return }
            let b = body.startIndex
            let len = Int(body[b]) << 8 | Int(body[b + 1])
            guard body.count >= 2 + len else { return }
            let topic = String(decoding: body[(b + 2)..<(b + 2 + len)], as: UTF8.self)
            var payloadStart = b + 2 + len
            let qos = (flags >> 1) & 0x03
            if qos > 0 {
                // Acknowledge QoS 1 (we subscribe with 0, but be polite).
                let pid = body[payloadStart..<(payloadStart + 2)]
                if qos == 1 { send(Data([0x40, 0x02]) + pid) }
                payloadStart += 2
            }
            continuation?.yield(MQTTMessage(topic: topic, payload: Data(body[payloadStart...])))
        default:
            break // SUBACK, UNSUBACK, PINGRESP
        }
    }

    private func startPinging() {
        pingTask?.cancel()
        let interval = UInt64(keepAlive / 2) * 1_000_000_000
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: interval)
                await self?.send(Data([0xC0, 0x00]))
            }
        }
    }

    private func nextPacketId() -> UInt16 {
        packetId = packetId == .max ? 1 : packetId + 1
        return packetId
    }

    // MARK: - Packet encoding

    static func encodeString(_ s: String) -> Data {
        let bytes = Array(s.utf8)
        return Data([UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes)
    }

    static func encodeRemainingLength(_ length: Int) -> Data {
        var x = length
        var out = Data()
        repeat {
            var byte = UInt8(x % 128)
            x /= 128
            if x > 0 { byte |= 0x80 }
            out.append(byte)
        } while x > 0
        return out
    }

    static func connectPacket(clientId: String, keepAlive: UInt16) -> Data {
        var variable = encodeString("MQTT")
        variable.append(4)        // protocol level 3.1.1
        variable.append(0x02)     // clean session
        variable.append(UInt8(keepAlive >> 8))
        variable.append(UInt8(keepAlive & 0xFF))
        let payload = encodeString(clientId)
        return Data([0x10]) + encodeRemainingLength(variable.count + payload.count) + variable + payload
    }

    private func subscribePacket(_ topics: [String]) -> Data {
        let pid = nextPacketId()
        var body = Data([UInt8(pid >> 8), UInt8(pid & 0xFF)])
        for t in topics {
            body.append(Self.encodeString(t))
            body.append(0) // QoS 0
        }
        return Data([0x82]) + Self.encodeRemainingLength(body.count) + body
    }

    private func unsubscribePacket(_ topics: [String]) -> Data {
        let pid = nextPacketId()
        var body = Data([UInt8(pid >> 8), UInt8(pid & 0xFF)])
        for t in topics { body.append(Self.encodeString(t)) }
        return Data([0xA2]) + Self.encodeRemainingLength(body.count) + body
    }

    /// Returns (packet type, flags, body, bytes consumed) for the first complete packet in `data`.
    static func parsePacket(_ data: Data) -> (type: UInt8, flags: UInt8, body: Data, consumed: Int)? {
        guard data.count >= 2 else { return nil }
        let start = data.startIndex
        let header = data[start]
        var multiplier = 1, value = 0, i = 1
        while true {
            guard start + i < data.endIndex else { return nil }
            let byte = data[start + i]
            value += Int(byte & 0x7F) * multiplier
            multiplier *= 128
            i += 1
            if byte & 0x80 == 0 { break }
            if i > 4 { return nil }
        }
        guard data.count >= i + value else { return nil }
        let body = data[(start + i)..<(start + i + value)]
        return (header >> 4, header & 0x0F, Data(body), i + value)
    }
}
