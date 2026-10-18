<p align="center">
  <img src="Assets/AppIcon.png" width="128" alt="RigWatch icon">
</p>

<h1 align="center">RigWatch</h1>

<p align="center">
  <b>Mission control for a developer's Mac.</b><br>
  See what your coding agents, emulators, simulators, builds and caches are doing to your machine,<br>
  and close what you don't need, safely.
</p>

<p align="center">
  <img src="docs/screenshots/overview-dark.png" alt="RigWatch overview: a chip-die map of what is using the machine">
</p>

## Why

A Mac running a few coding agents, an Android emulator, an iOS simulator and a Gradle daemon slows
down, and Activity Monitor won't tell you *why*: it lists 700 processes with no idea that forty of
them belong to one agent session, or that an emulator nobody has touched in two days is holding 6 GB.

RigWatch groups everything by **who started it** and shows it as one picture.

## What it shows

| Page | What you get |
| --- | --- |
| **Overview** | A chip-die map of the machine, sized by memory or CPU. Click any block to see what's inside it. Live CPU, memory, GPU, disk, network and chip temperature. |
| **Agent Sessions** | Every coding agent running, with its CPU, memory, processes, devices and worktrees. Claude Code, OpenCode and Codex also show the session title and last prompt, and can be resumed. Cursor, Windsurf, T3 Code, Gemini CLI, Aider, Goose and Amp are recognised from their processes. |
| **Emulators & Simulators** | Each Android emulator and iOS simulator: what it's showing, which session launched it, the last command a session ran on it, a live screen, and a graceful shut-down. |
| **Processes** | Grouped by app or tool, with CPU on one scale (100% = the whole machine) and quit or force-quit behind a confirmation. |
| **Memory** | Where the RAM went: apps, wired, compressed, file cache, swap and pressure. |
| **Worktrees** | Every `git worktree` under your home folders, which session made it, whether anything is using it, and a remove that refuses to lose uncommitted or unpushed work. |
| **Disk** | The whole drive as a chip-die map of folders. Click into any folder; right-click to show it in Finder. |

<p align="center">
  <img src="docs/screenshots/sessions-dark.png" width="49%" alt="Agent sessions">
  <img src="docs/screenshots/disk-dark.png" width="49%" alt="Disk map">
</p>
<p align="center">
  <img src="docs/screenshots/devices-dark.png" width="49%" alt="Emulators and simulators">
  <img src="docs/screenshots/worktrees-dark.png" width="49%" alt="Worktrees">
</p>
<p align="center">
  <img src="docs/screenshots/processes-dark.png" width="49%" alt="Processes">
  <img src="docs/screenshots/memory-dark.png" width="49%" alt="Memory">
</p>
<p align="center">
  <img src="docs/screenshots/overview-light.png" width="49%" alt="Overview, light theme">
  <img src="docs/screenshots/disk-light.png" width="49%" alt="Disk, light theme">
</p>

## Install

Requires **macOS 14 (Sonoma) or later** on Apple silicon (Intel is untested), and the Xcode Command Line Tools
(`xcode-select --install`).

```bash
git clone https://github.com/OWNER/rigwatch.git
cd rigwatch
./bundle.sh
open ~/Applications/RigWatch.app
```

`bundle.sh` builds a release binary, wraps it in `~/Applications/RigWatch.app` with its icon, and
signs it for this Mac. Run it again to update.

### From a release download

Release builds are not notarized by Apple, so macOS blocks the first launch. Either:

- open **System Settings → Privacy & Security**, scroll to the RigWatch message and click **Open Anyway**, or
- run `xattr -dr com.apple.quarantine /Applications/RigWatch.app` once.

### Try it without your own data

```bash
~/Applications/RigWatch.app/Contents/MacOS/RigWatch -demo
```

Demo mode fills every page with made-up sessions, devices and folders. Nothing is sampled, scanned
or closed while it is on. Every screenshot above was taken in it.

## Light on the machine it watches

- Samples every 5 seconds while the window is open (3, 5 or 10 s in the sidebar) and once a minute
  when it is hidden. Typically 0.1–2% of one core and 150–250 MB.
- Machine-wide numbers come from Mach, sysctl and IOKit directly, with no helper processes.
- Disk sizes use `du` at macOS background priority, at most three at a time. The automatic rescan
  runs at most every six hours; **Rescan** runs one now.
- The menu bar shows CPU and memory at a glance.

## Safety and privacy

- **Nothing is closed without asking.** Every quit, shut-down and removal shows what will happen
  and who is using it first. macOS's own processes and other users' processes are never offered.
- **Worktree removal is checked first**: anything with uncommitted changes, untracked files (other
  than build output), unpushed commits or a process inside it is kept.
- **Process environments are never stored.** RigWatch reads exactly two variables from its own
  processes, `CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_HOST_SESSION_ID`, to link processes to a
  session. Tokens and everything else in the environment are skipped.
- **Agent session files are read, never written**: Claude Code transcripts in `~/.claude/projects`,
  OpenCode's database (opened read-only), Codex's rollouts in `~/.codex/sessions`.
- **Nothing leaves the Mac.** No network calls, no analytics, no accounts.

## Why it isn't on the Mac App Store

App Store apps must run in Apple's sandbox, which forbids reading other processes, running `ps`,
`du`, `git`, `adb` or `simctl`, and closing other apps: everything RigWatch is for. The chip
temperature also comes from a private Apple interface, which App Review does not allow.

## Permissions

None are required. Without **Full Disk Access**, a few protected folders (Mail, Safari, other
users') can't be measured and are counted in the "System & protected" block instead.

## Building and hacking

```text
Sources/RigWatch/
  App.swift          app, window and menu bar
  Monitor.swift      the sampler loop, actions, disk scans
  SystemStats.swift  CPU, memory, GPU, disk, network, temperature
  Procs.swift        processes and grouping
  Agents.swift       agent detection; OpenCode and Codex session stores
  Sessions.swift     Claude Code transcripts
  Devices.swift      Android emulators (adb) and iOS simulators (simctl)
  Worktrees.swift    git worktrees and the safe-removal check
  Demo.swift         the -demo data set
  Theme.swift        colours, panels, gauges
  Views.swift        every page, and the chip-die treemap
Assets/make-icon.swift   draws Assets/AppIcon.png
```

`swift build` for a debug build, `./bundle.sh` for the app. To redraw the icon:
`swift Assets/make-icon.swift Assets/AppIcon.png`.

Adding an agent: give it a case in `Agent` (`Agents.swift`) and a line in `Agent.of` that recognises
its process. If it keeps session files, add a store like `OpenCodeStore` and match it to the live
process by working folder.

## Not affiliated

RigWatch is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic,
OpenAI, Cursor, Codeium, T3 or any other tool it detects. Product names are trademarks of their owners
and are used only to say what RigWatch recognises.

## License

[MIT](LICENSE)
