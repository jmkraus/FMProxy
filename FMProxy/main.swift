import Foundation
import Network

let configuration = ServerConfiguration(arguments: CommandLine.arguments)

if configuration.showHelp {
    print(ServerConfiguration.usage)
    exit(0)
}

do {
    let server = try HTTPServer(configuration: configuration)
    Task {
        do {
            try await server.start()
            print("FMProxy listening on http://\(configuration.host):\(configuration.port)")
            print("Press Ctrl-C to stop.")
            await server.waitUntilStopped()
        } catch {
            fputs("Failed to start FMProxy: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    dispatchMain()
} catch {
    fputs("Failed to start FMProxy: \(error.localizedDescription)\n", stderr)
    exit(1)
}
