import Foundation

enum DuckpadEditorResources {
    static var bundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent(
                   "Duckpad_DuckpadEditorAdapter.bundle",
                   isDirectory: true
               )
           ) {
            return packaged
        }
        return Bundle.module
    }
}
