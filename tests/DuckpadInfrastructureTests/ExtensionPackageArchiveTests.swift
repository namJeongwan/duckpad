import Foundation
import Testing
@testable import DuckpadInfrastructure

@Suite struct ExtensionPackageArchiveTests {
    @Test func nativeArchitectureMustMatchBeforePublication() {
        #if arch(arm64)
        let supported: UInt8 = 12, unsupported: UInt8 = 7
        #else
        let supported: UInt8 = 7, unsupported: UInt8 = 12
        #endif
        #expect(NativeModuleCompatibility.supportsCurrentProcess(Data([0xcf, 0xfa, 0xed, 0xfe, supported, 0, 0, 1])))
        #expect(!NativeModuleCompatibility.supportsCurrentProcess(Data([0xcf, 0xfa, 0xed, 0xfe, unsupported, 0, 0, 1])))
        #expect(!NativeModuleCompatibility.supportsCurrentProcess(Data()))
        let fat = Data([0xca, 0xfe, 0xba, 0xbe, 0, 0, 0, 1, 1, 0, 0, supported] + [UInt8](repeating: 0, count: 16))
        #expect(NativeModuleCompatibility.supportsCurrentProcess(fat))
        #expect(!NativeModuleCompatibility.supportsCurrentProcess(fat.prefix(12)))
    }
    private func stored(_ names: [String], symlink: Bool = false) -> Data {
        var data = Data(), central = Data()
        func put(_ value: Int, _ size: Int, into data: inout Data) {
            for shift in 0..<size { data.append(UInt8(truncatingIfNeeded: value >> (8 * shift))) }
        }
        for name in names {
            let bytes = Data(name.utf8), start = data.count
            put(0x04034b50,4,into:&data); put(20,2,into:&data)
            for _ in 0..<4 { put(0,2,into:&data) }
            for _ in 0..<3 { put(0,4,into:&data) }
            put(bytes.count,2,into:&data); put(0,2,into:&data); data.append(bytes)
            put(0x02014b50,4,into:&central); put(0x0314,2,into:&central); put(20,2,into:&central)
            for _ in 0..<4 { put(0,2,into:&central) }
            for _ in 0..<3 { put(0,4,into:&central) }
            put(bytes.count,2,into:&central)
            for _ in 0..<4 { put(0,2,into:&central) }
            put((symlink ? 0xa1ff : 0x81a4) << 16,4,into:&central); put(start,4,into:&central); central.append(bytes)
        }
        let directory = data.count; data.append(central)
        put(0x06054b50,4,into:&data); put(0,2,into:&data); put(0,2,into:&data)
        put(names.count,2,into:&data); put(names.count,2,into:&data)
        put(central.count,4,into:&data); put(directory,4,into:&data); put(0,2,into:&data)
        return data
    }
    @Test func readsStoredAndDeflatedPackages() throws {
        #expect(try ExtensionPackageArchive.decode(stored(["plugin.json", "module.dylib"])).count == 2)
        let files = try ExtensionPackageArchive.decode(Data(base64Encoded: "UEsDBBQAAAAIAHWBL10AAAAAAgAAAAAAAAAWAAAAc2FtcGxlLmR1Y2twYWQtcGx1Z2luLwMAUEsDBBQAAAAIAHWBL11Dv6ajBAAAAAIAAAAhAAAAc2FtcGxlLmR1Y2twYWQtcGx1Z2luL3BsdWdpbi5qc29uq64FAFBLAwQUAAAACAB1gS9d5VILqAwAAAAJAAAAJwAAAHNhbXBsZS5kdWNrcGFkLXBsdWdpbi9sb2NhbGUtamEuc3RyaW5nc3s2femzOWterJoHAFBLAQIUAxQAAAAIAHWBL10AAAAAAgAAAAAAAAAWAAAAAAAAAAAAEAD9QQAAAABzYW1wbGUuZHVja3BhZC1wbHVnaW4vUEsBAhQDFAAAAAgAdYEvXUO/pqMEAAAAAgAAACEAAAAAAAAAAAAAAIABNgAAAHNhbXBsZS5kdWNrcGFkLXBsdWdpbi9wbHVnaW4uanNvblBLAQIUAxQAAAAIAHWBL13lUguoDAAAAAkAAAAnAAAAAAAAAAAAAACAAXkAAABzYW1wbGUuZHVja3BhZC1wbHVnaW4vbG9jYWxlLWphLnN0cmluZ3NQSwUGAAAAAAMAAwDoAAAAygAAAAAA")!)
        #expect(files["plugin.json"] == Data("{}".utf8))
        #expect(files["locale-ja.strings"] == Data("日本語".utf8))
    }
    @Test func rejectsPathsLinksDuplicatesAndMixedRoots() {
        for names in [["../plugin.json"], ["/plugin.json"], ["x/../../plugin.json"], ["x\\plugin.json"], ["plugin.json", "plugin.json"], ["x.duckpad-plugin/plugin.json", "other.txt"], ["a.duckpad-plugin/plugin.json", "b.duckpad-plugin/other.txt"]] {
            #expect(throws: (any Error).self) { try ExtensionPackageArchive.decode(stored(names)) }
        }
        #expect(throws: (any Error).self) { try ExtensionPackageArchive.decode(stored(["plugin.json"], symlink: true)) }
    }
    @Test func rejectsTruncationOversizedFieldsAndCorruptContent() {
        let valid = stored(["plugin.json"])
        for end in 0..<valid.count { #expect(throws: (any Error).self) { try ExtensionPackageArchive.decode(Data(valid.prefix(end))) } }
        var huge = valid
        let central = 30 + "plugin.json".utf8.count
        huge[central + 24] = 255; huge[central + 25] = 255; huge[central + 26] = 255; huge[central + 27] = 127
        #expect(throws: (any Error).self) { try ExtensionPackageArchive.decode(huge) }
        var corrupt = Data(base64Encoded: "UEsDBBQAAAAIAHWBL10AAAAAAgAAAAAAAAAWAAAAc2FtcGxlLmR1Y2twYWQtcGx1Z2luLwMAUEsDBBQAAAAIAHWBL11Dv6ajBAAAAAIAAAAhAAAAc2FtcGxlLmR1Y2twYWQtcGx1Z2luL3BsdWdpbi5qc29uq64FAFBLAwQUAAAACAB1gS9d5VILqAwAAAAJAAAAJwAAAHNhbXBsZS5kdWNrcGFkLXBsdWdpbi9sb2NhbGUtamEuc3RyaW5nc3s2femzOWterJoHAFBLAQIUAxQAAAAIAHWBL10AAAAAAgAAAAAAAAAWAAAAAAAAAAAAEAD9QQAAAABzYW1wbGUuZHVja3BhZC1wbHVnaW4vUEsBAhQDFAAAAAgAdYEvXUO/pqMEAAAAAgAAACEAAAAAAAAAAAAAAIABNgAAAHNhbXBsZS5kdWNrcGFkLXBsdWdpbi9wbHVnaW4uanNvblBLAQIUAxQAAAAIAHWBL13lUguoDAAAAAkAAAAnAAAAAAAAAAAAAACAAXkAAABzYW1wbGUuZHVja3BhZC1wbHVnaW4vbG9jYWxlLWphLnN0cmluZ3NQSwUGAAAAAAMAAwDoAAAAygAAAAAA")!
        corrupt[35] ^= 1
        #expect(throws: (any Error).self) { try ExtensionPackageArchive.decode(corrupt) }
    }
}
