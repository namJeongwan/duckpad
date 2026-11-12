import Foundation

struct DiagramRender: Sendable {
    let svg: Data
    let png: Data
    let width: Int
    let height: Int
}
