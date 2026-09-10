import Foundation

nonisolated enum AudioWireCodec {
    private static let version: UInt8 = 1
    private static let fixedHeaderSize = 26

    static func encode(_ frame: AudioWireFrame) throws -> Data {
        let expectedByteCount =
            Int(frame.frameCount) * Int(AudioWireFrame.channelCount) * 2
        guard
            frame.frameCount > 0,
            frame.pcmInt16LittleEndian.count == expectedByteCount,
            expectedByteCount <= Int(UInt32.max)
        else {
            throw MediaWireError.invalidAudioFrame
        }

        var encoded = Data()
        encoded.reserveCapacity(fixedHeaderSize + expectedByteCount)
        encoded.append(version)
        encoded.appendBigEndian(frame.sequenceNumber)
        encoded.appendBigEndian(
            UInt64(bitPattern: frame.presentationTimeMicroseconds)
        )
        encoded.appendBigEndian(AudioWireFrame.sampleRate)
        encoded.append(AudioWireFrame.channelCount)
        encoded.appendBigEndian(frame.frameCount)
        encoded.append(frame.pcmInt16LittleEndian)
        return encoded
    }

    static func decode(_ data: Data) throws -> AudioWireFrame {
        var reader = MediaDataReader(data: data)
        guard try reader.readUInt8() == version else {
            throw MediaWireError.unsupportedVersion
        }

        let sequenceNumber = try reader.readUInt64()
        let presentationTime = Int64(bitPattern: try reader.readUInt64())
        let sampleRate = try reader.readUInt32()
        let channelCount = try reader.readUInt8()
        let frameCount = try reader.readUInt32()
        let payloadByteCount = Int(frameCount) * Int(channelCount) * 2

        guard
            sampleRate == AudioWireFrame.sampleRate,
            channelCount == AudioWireFrame.channelCount,
            frameCount > 0
        else {
            throw MediaWireError.invalidAudioFrame
        }

        let payload = try reader.readData(count: payloadByteCount)
        guard reader.isAtEnd else {
            throw MediaWireError.trailingData
        }
        return AudioWireFrame(
            sequenceNumber: sequenceNumber,
            presentationTimeMicroseconds: presentationTime,
            frameCount: frameCount,
            pcmInt16LittleEndian: payload
        )
    }
}

nonisolated enum VideoWireCodec {
    private static let version: UInt8 = 1
    private static let fixedHeaderSize = 35

    static func encode(_ frame: EncodedVideoFrame) throws -> Data {
        let parameterSets = frame.parameterSets
        let sequenceParameterSet = parameterSets?.sequenceParameterSet ?? Data()
        let pictureParameterSet = parameterSets?.pictureParameterSet ?? Data()

        guard
            sequenceParameterSet.count <= Int(UInt16.max),
            pictureParameterSet.count <= Int(UInt16.max),
            frame.payload.count <= Int(UInt32.max),
            (parameterSets?.nalUnitHeaderLength ?? 4) <= Int(UInt8.max)
        else {
            throw MediaWireError.invalidVideoFrame
        }

        var encoded = Data()
        encoded.reserveCapacity(
            fixedHeaderSize
                + sequenceParameterSet.count
                + pictureParameterSet.count
                + frame.payload.count
        )
        encoded.append(version)
        encoded.append(frame.isKeyFrame ? 1 : 0)
        encoded.appendBigEndian(frame.sequenceNumber)
        encoded.appendBigEndian(
            UInt64(bitPattern: frame.presentationTimeMicroseconds)
        )
        encoded.appendBigEndian(UInt64(bitPattern: frame.durationMicroseconds))
        encoded.appendBigEndian(UInt16(sequenceParameterSet.count))
        encoded.appendBigEndian(UInt16(pictureParameterSet.count))
        encoded.append(UInt8(parameterSets?.nalUnitHeaderLength ?? 4))
        encoded.appendBigEndian(UInt32(frame.payload.count))
        encoded.append(sequenceParameterSet)
        encoded.append(pictureParameterSet)
        encoded.append(frame.payload)
        return encoded
    }

    static func decode(_ data: Data) throws -> EncodedVideoFrame {
        var reader = MediaDataReader(data: data)
        guard try reader.readUInt8() == version else {
            throw MediaWireError.unsupportedVersion
        }

        let flags = try reader.readUInt8()
        let sequenceNumber = try reader.readUInt64()
        let presentationTime = Int64(bitPattern: try reader.readUInt64())
        let duration = Int64(bitPattern: try reader.readUInt64())
        let sequenceParameterSetLength = Int(try reader.readUInt16())
        let pictureParameterSetLength = Int(try reader.readUInt16())
        let nalUnitHeaderLength = Int(try reader.readUInt8())
        let payloadLength = Int(try reader.readUInt32())

        guard
            (1...4).contains(nalUnitHeaderLength),
            payloadLength > 0
        else {
            throw MediaWireError.invalidVideoFrame
        }

        let sequenceParameterSet = try reader.readData(
            count: sequenceParameterSetLength
        )
        let pictureParameterSet = try reader.readData(
            count: pictureParameterSetLength
        )
        let payload = try reader.readData(count: payloadLength)
        guard reader.isAtEnd else {
            throw MediaWireError.trailingData
        }

        let parameterSets: H264ParameterSets?
        if sequenceParameterSet.isEmpty && pictureParameterSet.isEmpty {
            parameterSets = nil
        } else {
            guard
                !sequenceParameterSet.isEmpty,
                !pictureParameterSet.isEmpty
            else {
                throw MediaWireError.invalidVideoFrame
            }
            parameterSets = H264ParameterSets(
                sequenceParameterSet: sequenceParameterSet,
                pictureParameterSet: pictureParameterSet,
                nalUnitHeaderLength: nalUnitHeaderLength
            )
        }

        return EncodedVideoFrame(
            sequenceNumber: sequenceNumber,
            presentationTimeMicroseconds: presentationTime,
            durationMicroseconds: duration,
            isKeyFrame: flags & 1 == 1,
            payload: payload,
            parameterSets: parameterSets
        )
    }
}

nonisolated enum MediaWireError: LocalizedError, Equatable {
    case unsupportedVersion
    case truncatedData
    case trailingData
    case invalidVideoFrame
    case invalidAudioFrame

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "The media packet uses an unsupported version."
        case .truncatedData:
            return "The media packet ended unexpectedly."
        case .trailingData:
            return "The media packet contained unexpected trailing data."
        case .invalidVideoFrame:
            return "The media packet contained an invalid video frame."
        case .invalidAudioFrame:
            return "The media packet contained an invalid audio frame."
        }
    }
}

private nonisolated struct MediaDataReader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw MediaWireError.truncatedData
        }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        let bytes = try readData(count: 2)
        return bytes.reduce(UInt16(0)) {
            ($0 << 8) | UInt16($1)
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        let bytes = try readData(count: 4)
        return bytes.reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    mutating func readUInt64() throws -> UInt64 {
        let bytes = try readData(count: 8)
        return bytes.reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }

    mutating func readData(count: Int) throws -> Data {
        guard
            count >= 0,
            offset <= data.count,
            count <= data.count - offset
        else {
            throw MediaWireError.truncatedData
        }
        let start = data.startIndex + offset
        let end = start + count
        offset += count
        return Data(data[start..<end])
    }
}

private nonisolated extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.bigEndian
        Swift.withUnsafeBytes(of: &value) {
            append(contentsOf: $0)
        }
    }
}
