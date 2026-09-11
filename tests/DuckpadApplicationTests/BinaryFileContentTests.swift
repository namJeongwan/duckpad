import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

struct BinaryFileContentTests {
    @Test func binaryDisplayIncludesTheFullTailAndIsMarkedReadOnly() {
        let data = Data(repeating: 0, count: 2 * 1_024 * 1_024) + Data("tail".utf8)
        let decoded = TextFileCodec.decodeForDisplay(data)
        #expect(decoded.binaryByteCount == data.count)
        #expect(decoded.text.utf8.count == data.count)
        #expect(decoded.text.hasSuffix("tail"))
        #expect(TextFileCodec.decodeForDisplay(Data([0xFF])).binaryByteCount == 1)
    }

    @Test func nativeMetadataDoesNotDecodeBinaryBytes() {
        let data = Data(repeating: 0xFF, count: 2 * 1_024 * 1_024)
        let decoded = BinaryFileContent.decode(data, decodingText: false)
        #expect(decoded.text.isEmpty)
        #expect(decoded.binaryByteCount == data.count)
    }

    @Test func validUnicodeRemainsEditableIncludingASplitSampleScalar() {
        let text = String(repeating: "a", count: 65_535) + "🦆한글\r\n"
        for encoding in TextFileEncoding.allCases {
            let data = TextFileCodec.encode(text, encoding: encoding, byteOrderMark: .present)
            let decoded = TextFileCodec.decodeForDisplay(data)
            #expect(decoded.binaryByteCount == nil)
            #expect(decoded.text == text)
            #expect(decoded.encoding == encoding)
            #expect(decoded.lineEnding == .crlf)
        }
        let data = Data(text.utf8)
        #expect(!BinaryFileContent.isBinary(data))
        #expect(TextFileCodec.decodeForDisplay(data).text == text)
        #expect(TextFileCodec.decodeForDisplay(Data()).binaryByteCount == nil)
    }
}
