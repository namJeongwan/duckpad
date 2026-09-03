import Foundation

enum DuckpadInfrastructureResources {
    static var bundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent(
                   "Duckpad_DuckpadInfrastructure.bundle",
                   isDirectory: true
               )
           ) {
            return packaged
        }
        return Bundle.module
    }
}
