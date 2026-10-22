import Foundation

// `RigWatch <command>` (run, hook, reap, status, …) is the Rules command line: it runs and exits
// before anything of the app starts. Anything else opens the app.
if let code = CLI.main(Array(CommandLine.arguments.dropFirst())) { exit(code) }
RigWatchApp.main()
