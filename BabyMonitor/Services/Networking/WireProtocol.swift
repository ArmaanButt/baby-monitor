import Foundation

nonisolated enum WirePacketType: UInt8, Equatable, Sendable {
    case control = 1
    case video = 2
    case audio = 3
}

nonisolated struct WirePacket: Equatable, Sendable {
    let type: WirePacketType
    let payload: Data
}

nonisolated enum WirePacketCodec {
    static let maximumPacketSize = 8 * 1_024 * 1_024

    static func encode(_ packet: WirePacket) throws -> Data {
        let bodyLength = packet.payload.count + 1
        guard bodyLength <= maximumPacketSize else {
            throw WireProtocolError.packetTooLarge
        }

        var encoded = Data()
        encoded.reserveCapacity(bodyLength + 4)
        var length = UInt32(bodyLength).bigEndian
        withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
        encoded.append(packet.type.rawValue)
        encoded.append(packet.payload)
        return encoded
    }
}

nonisolated struct WirePacketFramer {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [WirePacket] {
        buffer.append(data)
        var packets: [WirePacket] = []

        while buffer.count >= 4 {
            let bodyLength =
                Int(buffer[buffer.startIndex]) << 24
                | Int(buffer[buffer.startIndex + 1]) << 16
                | Int(buffer[buffer.startIndex + 2]) << 8
                | Int(buffer[buffer.startIndex + 3])

            guard bodyLength > 0, bodyLength <= WirePacketCodec.maximumPacketSize else {
                throw WireProtocolError.invalidLength
            }
            guard buffer.count >= bodyLength + 4 else {
                break
            }

            let typeIndex = buffer.startIndex + 4
            guard let type = WirePacketType(rawValue: buffer[typeIndex]) else {
                throw WireProtocolError.unknownPacketType
            }

            let payloadStart = typeIndex + 1
            let payloadEnd = buffer.startIndex + 4 + bodyLength
            let payload = Data(buffer[payloadStart..<payloadEnd])
            packets.append(WirePacket(type: type, payload: payload))
            buffer.removeFirst(bodyLength + 4)
        }

        return packets
    }
}

nonisolated enum WireProtocolError: LocalizedError, Equatable {
    case packetTooLarge
    case invalidLength
    case unknownPacketType
    case invalidControlMessage

    var errorDescription: String? {
        switch self {
        case .packetTooLarge:
            return "A local-network packet exceeded the allowed size."
        case .invalidLength:
            return "A local-network packet had an invalid length."
        case .unknownPacketType:
            return "A local-network packet had an unknown type."
        case .invalidControlMessage:
            return "A local-network control message was invalid."
        }
    }
}

nonisolated struct ControlMessage: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case clientHello
        case pairingChallenge
        case pairingProof
        case pairingAccepted
        case authenticationChallenge
        case authenticationResponse
        case authenticated
        case revoked
        case stop
    }

    static let currentProtocolVersion = 1

    var kind: Kind
    var protocolVersion = currentProtocolVersion
    var peerID: String?
    var peerName: String?
    var hasStoredPairing: Bool?
    var clientNonce: Data?
    var serverNonce: Data?
    var clientPublicKey: Data?
    var serverPublicKey: Data?
    var proof: Data?
    var encryptedPairingSecret: Data?
}

nonisolated enum ControlMessageCodec {
    static func encode(_ message: ControlMessage) throws -> Data {
        let payload = try JSONEncoder().encode(message)
        return try WirePacketCodec.encode(
            WirePacket(type: .control, payload: payload)
        )
    }

    static func decode(_ payload: Data) throws -> ControlMessage {
        let message = try JSONDecoder().decode(ControlMessage.self, from: payload)
        guard message.protocolVersion == ControlMessage.currentProtocolVersion else {
            throw WireProtocolError.invalidControlMessage
        }
        return message
    }
}
