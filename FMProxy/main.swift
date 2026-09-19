import Foundation
import Network

let configuration = ServerConfiguration(arguments: CommandLine.arguments)

if configuration.showHelp {
    print(ServerConfiguration.usage)
    exit(0)
}

let server = HTTPServer(configuration: configuration)

do {
    try server.start()
    print("FMProxy listening on http://\(configuration.host):\(configuration.port)")
    print("Press Ctrl-C to stop.")
    dispatchMain()
} catch {
    fputs("Failed to start FMProxy: \(error.localizedDescription)\n", stderr)
    exit(1)
}
