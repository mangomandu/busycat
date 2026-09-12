import Foundation

enum SMCValueDecoder {
    /// Input is in the reversed byte order returned by SMCReader.readKey.
    static func temperature(_ data: [UInt8], type: String) -> Double? {
        switch type {
        case "sp78":
            guard data.count == 2 else { return nil }
            let bits = UInt16(data[1]) << 8 | UInt16(data[0])
            return Double(Int16(bitPattern: bits)) / 256.0
        case "flt ":
            guard data.count == 4 else { return nil }
            let bits = data.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            return Double(Float32(bitPattern: bits))
        default:
            return nil
        }
    }
}
