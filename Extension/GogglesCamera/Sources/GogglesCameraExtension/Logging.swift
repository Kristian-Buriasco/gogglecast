import os

enum Logging {
    static let subsystem = "com.kburiasco.gogglesview.camera"
    static let camera = Logger(subsystem: subsystem, category: "Camera")
    static let helper = Logger(subsystem: subsystem, category: "HelperFeed")
    static let decode = Logger(subsystem: subsystem, category: "Decode")
}
