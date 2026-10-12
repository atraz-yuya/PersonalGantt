import Foundation
import CryptoKit

/// A bounded TCP record: protocol magic/version, big-endian length, SHA256, payload.
/// The envelope inside it retains the existing kind and schema validation.
nonisolated struct LocalSyncFrame {
    private static let magic = Data([0x50, 0x47, 0x53, 1])
    private static let headerSize = 40
    private var buffer = Data()
    private var expectedSize: Int?
    static func encode(_ payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw LocalSyncError.invalidData }
        guard payload.count <= LocalSyncConstants.maximumBytes else { throw LocalSyncError.tooLarge }
        let size = UInt32(payload.count)
        var frame = magic
        frame.append(contentsOf: [UInt8(size >> 24), UInt8(truncatingIfNeeded: size >> 16), UInt8(truncatingIfNeeded: size >> 8), UInt8(truncatingIfNeeded: size)])
        frame.append(contentsOf: SHA256.hash(data: payload)); frame.append(payload)
        return frame
    }
    mutating func append(_ input: Data, receive: (Data) throws -> Void) throws {
        var offset = 0
        while offset < input.count {
            let target = expectedSize ?? Self.headerSize
            let count = min(target - buffer.count, input.count - offset)
            buffer.append(input.subdata(in: offset..<(offset + count))); offset += count
            guard buffer.count == target else { continue }
            if expectedSize == nil {
                guard buffer.prefix(4) == Self.magic else { throw LocalSyncError.version }
                let size = buffer[4..<8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0 else { throw LocalSyncError.invalidData }
                guard size <= LocalSyncConstants.maximumBytes else { throw LocalSyncError.tooLarge }
                expectedSize = Self.headerSize + Int(size)
            } else {
                let payload = Data(buffer.dropFirst(Self.headerSize))
                guard Data(buffer[8..<40]) == Data(SHA256.hash(data: payload)) else { throw LocalSyncError.invalidData }
                buffer.removeAll(keepingCapacity: false); expectedSize = nil
                try receive(payload)
            }
        }
    }
    func finish() throws { guard buffer.isEmpty else { throw LocalSyncError.invalidData } }
}
