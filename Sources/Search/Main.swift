import Foundation

// Search starts here: as the browser, or — started by a chat's agent as its
// MCP server — as a pipe to the chat's socket (MCPPipe), with no window, no
// Dock icon and none of the browser's state.
@main
enum Main {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.count >= 2, arguments[1] == "--mcp" {
            guard arguments.count == 4 else {
                FileHandle.standardError.write(Data("usage: Search --mcp <socket> <token>\n".utf8))
                exit(2)
            }
            exit(MCPPipe.run(socket: arguments[2], token: arguments[3]))
        }
        SearchApp.main()
    }
}
