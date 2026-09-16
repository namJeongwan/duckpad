import Foundation

enum NativeModuleCompatibility {
    static func supportsCurrentProcess(_ data: Data) -> Bool {
        #if arch(arm64)
        let cpu = 0x0100000c
        #else
        let cpu = 0x01000007
        #endif
        let bytes = [UInt8](data.prefix(8 + 32 * 20))
        guard bytes.count >= 8 else { return false }
        func number(_ index: Int, little: Bool) -> Int {
            (0..<4).reduce(0) { $0 | Int(bytes[index + $1]) << (8 * (little ? $1 : 3 - $1)) }
        }
        if Array(bytes.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] { return number(4, little: true) == cpu }
        let magic = Array(bytes.prefix(4))
        guard magic == [0xca, 0xfe, 0xba, 0xbe] || magic == [0xbe, 0xba, 0xfe, 0xca] else { return false }
        let little = magic[0] == 0xbe
        let count = number(4, little: little)
        guard count > 0, count <= 32, bytes.count >= 8 + count * 20 else { return false }
        return (0..<count).contains { number(8 + $0 * 20, little: little) == cpu }
    }
}
