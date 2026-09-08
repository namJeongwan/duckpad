import DuckpadApplication
import DuckpadDomain
@testable import DuckpadPresentation
import Foundation
import Testing

@Test func payloadRoundTripsItsTabAndSourceGroup() throws {
    let payload = EditorGroupDragPayload(tabID: TabID(), sourceGroup: .secondary)

    let decoded = try #require(EditorGroupDragPayload(data: payload.encodedData()))

    #expect(decoded == payload)
}

@Test func payloadRejectsUnknownVersionMalformedUUIDAndUnknownGroup() {
    let tabID = UUID().uuidString
    let invalidPayloads = [
        #"{"version":2,"tabID":"\#(tabID)","sourceGroup":"primary"}"#,
        #"{"version":1,"tabID":"not-a-uuid","sourceGroup":"primary"}"#,
        #"{"version":1,"tabID":"\#(tabID)","sourceGroup":"other"}"#,
    ]

    for invalidPayload in invalidPayloads {
        #expect(EditorGroupDragPayload(data: Data(invalidPayload.utf8)) == nil)
    }
}

@Test func payloadRejectsOversizedDataBeforeDecoding() {
    let payload = EditorGroupDragPayload(tabID: TabID(), sourceGroup: .primary)
    let oversizedData = payload.encodedData() + Data(repeating: 0x20, count: 1_024)

    #expect(EditorGroupDragPayload(data: oversizedData) == nil)
}

@Test func payloadRejectsBooleanFloatingPointAndStringVersions() {
    let tabID = UUID().uuidString
    let invalidPayloads = [
        #"{"version":true,"tabID":"\#(tabID)","sourceGroup":"primary"}"#,
        #"{"version":1.0,"tabID":"\#(tabID)","sourceGroup":"primary"}"#,
        #"{"version":"1","tabID":"\#(tabID)","sourceGroup":"primary"}"#,
    ]

    for invalidPayload in invalidPayloads {
        #expect(EditorGroupDragPayload(data: Data(invalidPayload.utf8)) == nil)
    }
}

@Test func optionModifierSelectsCopyAndOtherDragsSelectMove() {
    #expect(EditorGroupDragPayload.dropOperation(optionPressed: true) == .copy)
    #expect(EditorGroupDragPayload.dropOperation(optionPressed: false) == .move)
}
