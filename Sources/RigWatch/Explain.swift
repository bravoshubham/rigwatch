import Foundation

/// Plain-language notes for processes people see near the top and don't recognise: what it is, why
/// it gets busy, and what (if anything) to do about it.
struct Explanation {
    let what: String
    let why: String
    let todo: String
}

enum Explain {
    private static let settle = "Nothing: it settles on its own."
    private static let spotlightTodo = "Let it finish. To stop it indexing build output, add folders like node_modules, DerivedData, .gradle and build to System Settings › Spotlight › Search Privacy."
    private static let syncTodo = "Let the sync finish. Keep build output and node_modules out of synced folders (Desktop and Documents, when iCloud syncs them)."

    private static let table: [String: Explanation] = {
        let t: [String: Explanation] = [
            "kernel_task": .init(what: "The macOS kernel. It also takes CPU time on purpose to keep a hot chip from overheating.",
                                 why: "High numbers usually mean the Mac is hot: the kernel occupies the CPU so other work runs slower and cooler.",
                                 todo: "Nothing to quit. Find what is making the heat (the other top entries) and let the Mac cool."),
            "WindowServer": .init(what: "Draws everything on screen: windows, animations, every display.",
                                  why: "More windows, external or high-refresh displays, animations, screen sharing and recording all add to it.",
                                  todo: "Close windows and tabs you don't need; quit apps that animate in the background."),
            "launchd": .init(what: "The first process: starts and supervises every other one.", why: "Rarely busy; brief spikes when many processes start at once.", todo: settle),
            "mds": .init(what: "Spotlight's index server.", why: "Busy after many files change: builds, git checkouts, installs, a new disk or a macOS update.", todo: spotlightTodo),
            "mds_stores": .init(what: "Spotlight indexing: writes the search index.", why: "Busy after many files change: builds, git checkouts, node_modules installs, a macOS update.", todo: spotlightTodo),
            "mdworker": .init(what: "Spotlight importer: reads files so Spotlight can index them.", why: "Many run at once after lots of files change.", todo: spotlightTodo),
            "mdworker_shared": .init(what: "Spotlight importer: reads files so Spotlight can index them.", why: "Many run at once after lots of files change.", todo: spotlightTodo),
            "mdbulkimport": .init(what: "Spotlight importer for large batches of files.", why: "Busy after lots of files change.", todo: spotlightTodo),
            "corespotlightd": .init(what: "Indexes app content (Mail, Notes, Messages, apps' own data) for Spotlight.", why: "Busy after a lot of new app data arrives.", todo: settle),
            "Spotlight": .init(what: "The Spotlight search window.", why: "Busy while you search.", todo: settle),
            "photoanalysisd": .init(what: "Analyses your Photos library: people, scenes, memories.", why: "Runs after new photos arrive, mostly while the Mac is idle or charging.", todo: "Nothing: it pauses when you use the Mac and finishes in the background."),
            "mediaanalysisd": .init(what: "Analyses images and video for Live Text, Visual Look Up and Photos.", why: "Busy after many new images or videos arrive.", todo: settle),
            "backupd": .init(what: "Time Machine, making a backup.", why: "Busy during a backup, longer after many files changed.", todo: "Let it finish, or skip this backup from the Time Machine menu."),
            "cloudd": .init(what: "iCloud's sync engine (CloudKit), used by iCloud Drive, Photos and apps.", why: "Busy while a lot of data syncs.", todo: syncTodo),
            "bird": .init(what: "iCloud Drive's sync process.", why: "Busy while many files upload or download.", todo: syncTodo),
            "fileproviderd": .init(what: "Manages cloud folders: iCloud Drive, Dropbox, Google Drive, OneDrive.", why: "Busy while many files in a cloud folder change or sync.", todo: syncTodo),
            "nsurlsessiond": .init(what: "Runs background downloads and uploads for apps and macOS.", why: "Busy during large transfers: updates, iCloud, App Store, app downloads.", todo: settle),
            "softwareupdated": .init(what: "Checks for, downloads and prepares macOS updates.", why: "Busy while an update downloads or is prepared.", todo: "Let it finish, or install the pending update when convenient."),
            "coreaudiod": .init(what: "The audio system.", why: "Busy while sound plays or records; more with many audio apps or Bluetooth audio.", todo: "Quit apps or close pages that hold audio open while silent."),
            "trustd": .init(what: "Checks certificates and code signatures.", why: "Busy with many new network connections or many freshly built and signed binaries.", todo: settle),
            "syspolicyd": .init(what: "Gatekeeper: checks apps and programs the first time they run.", why: "Builds that produce new executables (each test run, each build) keep it busy.",
                                todo: "Usually nothing. Adding your terminal under System Settings › Privacy & Security › Developer Tools skips these checks for what it runs: only do that for code you trust."),
            "XprotectService": .init(what: "XProtect, macOS's built-in malware scanner.", why: "Scans new and changed apps and files, more after installs and updates.", todo: settle),
            "XProtect": .init(what: "XProtect, macOS's built-in malware scanner.", why: "Scans new and changed apps and files, more after installs and updates.", todo: settle),
            "launchd_sim": .init(what: "The launchd of a booted iOS simulator: its children are that simulator's processes.", why: "Each booted simulator runs a full set of iOS services.", todo: "Shut down simulators you aren't using (Emulators & Simulators page)."),
            "distnoted": .init(what: "Delivers notifications between processes.", why: "Busy when an app sends a flood of notifications.", todo: "Usually brief. If it stays busy, the app at the top next to it is the cause."),
            "logd": .init(what: "Collects the system log.", why: "Busy when something logs heavily: debug builds, simulators, verbose tools.", todo: "Quit or quieten the process that is logging."),
            "powerd": .init(what: "Power management: sleep, battery and what keeps the Mac awake.", why: "Rarely busy.", todo: settle),
            "configd": .init(what: "Network and system configuration.", why: "Busy when the network changes: Wi-Fi switches, VPNs connecting.", todo: settle),
            "mDNSResponder": .init(what: "DNS and Bonjour: looks up host names.", why: "Busy with many lookups, e.g. a build fetching lots of packages.", todo: settle),
            "opendirectoryd": .init(what: "Looks up users and groups.", why: "Busy when many processes look up users at once.", todo: settle),
            "fseventsd": .init(what: "Records file changes for apps that watch folders (Spotlight, Time Machine, dev server file watchers).", why: "Busy when many files change: builds, git checkouts, installs.", todo: settle),
            "bluetoothd": .init(what: "Bluetooth.", why: "Busy with many devices or while audio streams over Bluetooth.", todo: settle),
            "sharingd": .init(what: "AirDrop, Handoff and other Continuity features.", why: "Busy while it looks for or talks to nearby devices.", todo: settle),
            "locationd": .init(what: "Location Services.", why: "Busy while apps ask for your location.", todo: settle),
            "ReportCrash": .init(what: "Writes a crash report when an app crashes.", why: "Stays busy when something crashes again and again.", todo: "Find the crashing app in Console › Crash Reports and quit or fix it."),
            "spindump": .init(what: "Records what a hung app was doing.", why: "Runs when an app stops responding.", todo: "Look for the app that is hanging; spindump stops when it does."),
            "iconservicesagent": .init(what: "Builds the icons apps and Finder show.", why: "Busy after installing apps or opening folders with many files.", todo: settle),
            "quicklookd": .init(what: "Makes Quick Look previews and thumbnails.", why: "Busy when Finder shows a folder full of files.", todo: settle),
            "runningboardd": .init(what: "Tracks which apps are running and what they may use.", why: "Busy when many apps start or stop.", todo: settle),
            "WallpaperVideoExtension": .init(what: "Plays a moving (aerial) wallpaper.", why: "Decodes video for as long as a moving wallpaper shows.", todo: "Pick a still wallpaper if you want this gone."),
            "com.apple.WebKit.WebContent": .init(what: "A web page, in Safari or in an app that shows web content.", why: "Heavy pages, video and many open tabs.", todo: "Close tabs you don't need."),
            "com.apple.Virtualization.VirtualMachine": .init(what: "A virtual machine (Docker, UTM, Lima and others use these).", why: "Everything running inside the VM shows up here.", todo: "Stop containers or VMs you don't need, or quit the app that runs them."),
            "sysmond": .init(what: "Supplies process statistics to Activity Monitor and similar tools.", why: "Busy while such a tool is open and refreshing.", todo: "Close Activity Monitor when you aren't using it."),
        ]
        return t
    }()

    static func of(_ name: String) -> Explanation? { table[name] }
}
