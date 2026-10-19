import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

struct LegacyEncodingTests {
    @Test func knownBytesRoundTripWithoutBOM() throws {
        let fixtures: [(TextFileEncoding, String, [UInt8])] = [
            (.windows949, "한글뷁", [0xC7, 0xD1, 0xB1, 0xDB, 0x94, 0xEE]),
            (.eucKR, "한글", [0xC7, 0xD1, 0xB1, 0xDB]),
            (.shiftJIS, "日本語", [0x93, 0xFA, 0x96, 0x7B, 0x8C, 0xEA]),
            (.windows1252, "café €", [0x63, 0x61, 0x66, 0xE9, 0x20, 0x80]),
            (.windows1251, "Привет", [0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2]),
            (.isoLatin1, "café", [0x63, 0x61, 0x66, 0xE9]),
            (.gb18030, "中文🦆", [0xD6, 0xD0, 0xCE, 0xC4, 0x95, 0x30, 0xD8, 0x38]),
            (.big5, "繁體中文", [0xC1, 0x63, 0xC5, 0xE9, 0xA4, 0xA4, 0xA4, 0xE5]),
        ]
        #expect(Set(fixtures.map(\.0)) == Set(TextFileEncoding.legacyEncodings))
        for (encoding, text, bytes) in fixtures {
            let decoded = try TextFileCodec.decode(Data(bytes), assuming: encoding)
            #expect(decoded.text.utf8.elementsEqual(text.utf8))
            #expect(decoded.encoding == encoding)
            #expect(decoded.byteOrderMark == .absent)
            #expect(try TextFileCodec.encode(text, encoding: encoding, byteOrderMark: .absent) == Data(bytes))
            #expect(TextFileCodec.decodeForDisplay(Data(bytes), assuming: encoding).binaryByteCount == nil)
            let saved = try TextFileCodec.encodeUTF8(Data((text + "\nend").utf8), encoding: encoding,
                byteOrderMark: .absent, lineEnding: .crlf)
            #expect(try TextFileCodec.decode(saved, assuming: encoding).text == text + "\r\nend")
            #expect(try TextFileCodec.encode("", encoding: encoding, byteOrderMark: .absent).isEmpty)
            #expect(throws: TextFileCodecError.unsupportedByteOrderMark(encoding)) {
                try TextFileCodec.encode(text, encoding: encoding, byteOrderMark: .present)
            }
        }
    }

    @Test func incompatibleCharactersAndPartialSequencesAreRejected() throws {
        for encoding in TextFileEncoding.legacyEncodings where encoding != .gb18030 {
            #expect(throws: TextFileCodecError.unrepresentableCharacters(encoding)) {
                try TextFileCodec.encode("🦆", encoding: encoding, byteOrderMark: .absent)
            }
        }
        for encoding in [TextFileEncoding.windows949, .eucKR, .shiftJIS, .gb18030, .big5] {
            #expect(throws: TextFileCodecError.invalidBytes(encoding)) {
                try TextFileCodec.decode(Data([0x81]), assuming: encoding)
            }
        }
        #expect(throws: TextFileCodecError.invalidBytes(.eucKR)) {
            try TextFileCodec.decode(Data([0x94, 0xEE]), assuming: .eucKR)
        }
        #expect(throws: TextFileCodecError.unrepresentableCharacters(.windows1252)) {
            try TextFileCodec.encode("e\u{301}", encoding: .windows1252, byteOrderMark: .absent)
        }
        #expect(throws: TextFileCodecError.invalidUTF8) { try TextFileCodec.decode(Data([0xC7, 0xD1])) }
    }

    @Test func explicitMultibyteEncodingDoesNotMisclassifyASplitAnalysisSample() throws {
        let text = String(repeating: "a", count: 65_535) + "한글"
        let data = try TextFileCodec.encode(text, encoding: .windows949, byteOrderMark: .absent)
        #expect(!BinaryFileContent.isBinary(data, assuming: .windows949))
        #expect(TextFileCodec.decodeForDisplay(data, assuming: .windows949).text == text)
        #expect(BinaryFileContent.isBinary(Data([0, 0, 0]), assuming: .windows949))
    }
}
