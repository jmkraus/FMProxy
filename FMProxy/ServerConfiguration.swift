import Foundation

struct ServerConfiguration {
    let host: String
    let port: UInt16
    let noLogs: Bool
    let validateStructuredOutput: Bool
    let showHelp: Bool

    static let usage = """
    Usage: fmproxy-bin [options]

    Options:
      --host <host>   Bind host (default: 127.0.0.1)
      --port <port>   Listen port (default: 8080)
      --no-logs       Suppress request logging
      --validate-structured-output
                      Validate generated JSON against the requested schema
      --help, -h      Show this help and exit
    """

    init(arguments: [String]) {
        var host = "127.0.0.1"
        var port: UInt16 = 8080
        var noLogs = false
        var validateStructuredOutput = false
        var showHelp = false
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--help", "-h":
                showHelp = true
                index += 1
            case "--host" where index + 1 < arguments.count:
                host = arguments[index + 1]
                index += 2
            case "--port" where index + 1 < arguments.count:
                if let value = UInt16(arguments[index + 1]), value > 0 {
                    port = value
                }
                index += 2
            case "--no-logs":
                noLogs = true
                index += 1
            case "--validate-structured-output":
                validateStructuredOutput = true
                index += 1
            default:
                index += 1
            }
        }

        self.host = host
        self.port = port
        self.noLogs = noLogs
        self.validateStructuredOutput = validateStructuredOutput
        self.showHelp = showHelp
    }
}
