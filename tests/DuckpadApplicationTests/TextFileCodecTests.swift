import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

@Test func koreanEmojiRoundTripsAcrossSupportedEncodingsAndEndings() throws {
    let cases: [(TextFileEncoding, ByteOrderMark)] = [
        (.utf8, .absent), (.utf8, .present),
        (.utf16LittleEndian, .present), (.utf16BigEndian, .present),
    ]
    for (encoding, bom) in cases {
        for (ending, separator) in [(LineEnding.lf, "\n"), (.crlf, "\r\n"), (.cr, "\r")] {
            let text = "한글🙂e\u{301}\(separator)둘째\(separator)"
            let bytes = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: bom)
            let decoded = try TextFileCodec.decode(bytes)
            #expect(decoded.text == text)
            #expect(decoded.encoding == encoding)
            #expect(decoded.byteOrderMark == bom)
            #expect(decoded.lineEnding == ending)
        }
    }
}

@Test func emptyAndStrictInvalidInputAreDistinguished() throws {
    let empty = try TextFileCodec.decode(Data())
    #expect(empty.text.isEmpty)
    #expect(empty.encoding == .utf8)
    #expect(empty.lineEnding == .none)
    #expect(throws: TextFileCodecError.invalidUTF8) { try TextFileCodec.decode(Data([0xFF])) }
    #expect(throws: TextFileCodecError.truncatedUTF16) { try TextFileCodec.decode(Data([0xFF, 0xFE, 0x61])) }
    #expect(throws: TextFileCodecError.invalidUTF16) {
        try TextFileCodec.decode(Data([0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00]))
    }
}

@Test func explicitLineEndingConversionDoesNotAlterUnicode() {
    #expect(TextFileCodec.convert("한\r\n🙂\r끝\n", to: .lf) == "한\n🙂\n끝\n")
    #expect(TextFileCodec.convert("한\n🙂", to: .crlf) == "한\r\n🙂")
}

@Test func callerSelectedUTF16WithoutBOMRoundTripsStrictly() throws {
    let text = "한글🙂e\u{301}\r\n끝"
    for encoding in [TextFileEncoding.utf16LittleEndian, .utf16BigEndian] {
        let bytes = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: .absent)
        #expect(throws: TextFileCodecError.invalidUTF8) { try TextFileCodec.decode(bytes) }
        let selected = try TextFileCodec.decode(bytes, assuming: encoding)
        #expect(selected.text == text)
        #expect(selected.encoding == encoding)
        #expect(selected.byteOrderMark == .absent)
        #expect(selected.lineEnding == .crlf)
    }
}
