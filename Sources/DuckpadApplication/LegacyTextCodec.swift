import CoreFoundation
import Foundation
import DuckpadDomain

/// Use macOS converters without lossy substitutions or implicit normalization.
enum LegacyTextCodec {
    private static func foundationEncoding(_ encoding: TextFileEncoding) -> String.Encoding? {
        let name: String
        switch encoding {
        case .windows949: name = "windows-949"
        case .eucKR: name = "euc-kr"
        case .shiftJIS: name = "windows-31j"
        case .windows1252: name = "windows-1252"
        case .windows1251: name = "windows-1251"
        case .isoLatin1: name = "iso-8859-1"
        case .gb18030: name = "gb18030"
        case .big5: name = "big5"
        default: return nil
        }
        let identifier = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard CFStringIsEncodingAvailable(identifier) else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(identifier))
    }

    static func decode(_ data: Data, encoding: TextFileEncoding) throws(TextFileCodecError) -> String {
        guard let converter = foundationEncoding(encoding),
              let text = String(data: data, encoding: converter) else { throw .invalidBytes(encoding) }
        return text
    }

    static func encode(_ text: String, encoding: TextFileEncoding) throws(TextFileCodecError) -> Data {
        guard let converter = foundationEncoding(encoding),
              let data = text.data(using: converter, allowLossyConversion: false),
              let roundTrip = String(data: data, encoding: converter),
              roundTrip.utf8.elementsEqual(text.utf8) else {
            // Swift String equality allows canonical equivalence; compare exact
            // UTF-8 instead so a converter cannot silently compose characters.
            throw .unrepresentableCharacters(encoding)
        }
        return data
    }
}
