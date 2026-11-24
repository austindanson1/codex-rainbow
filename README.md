# Codex Rainbow

Give each local Codex chat a soft background that scrolls with its title. Every folder gets its own eight-color sequence. Chat IDs keep colors stable through renames, reordering and relaunches. You can also assign colors yourself.

## Install with one Codex prompt

> Install Codex Rainbow on my Mac from https://github.com/austindanson1/codex-rainbow. Clone the repository, review and run its install.sh, and verify the installed launcher. Put it in my Codex Dock spot and keep my current chats running.

On your next cold start, click **Codex Rainbow** in the Dock. It opens the installed Codex desktop app with your usual account and saved colors. Spotlight users can search for **Codex Rainbow**. If Codex is already running, Rainbow brings its windows forward. Quit Codex normally when you're ready to use the new launcher for the first time.

The launcher is the entry point that applies the stylesheet. Opening the stock app directly, following a chat link while Codex is quit, or an updater that restarts Codex itself can start a session without colors. Quit that session and reopen from the Rainbow icon.

### Manual installation

Requires macOS, Apple’s Command Line Tools (including Swift and Python 3), and a compatible Codex desktop app. Rainbow uses Codex’s bundled Node runtime when available. Builds without it require Node.js 20+ in a standard Homebrew or /usr/local installation.

```sh
git clone https://github.com/austindanson1/codex-rainbow.git
cd codex-rainbow
./install.sh
```

The installer builds from source, installs to `~/Applications/Codex Rainbow.app` and replaces a pinned Codex tile in place. If Codex was unpinned, it adds one tile. Run `./install.sh --no-dock` to manage the shortcut yourself. You can rerun the installer to upgrade. Installed copies work independently of the source checkout.

## Choose a color

Ask Codex, for example:

> Use the installed Codex Rainbow CLI to find my drum-production chat and make it turquoise. Ask if more than one chat matches.

```sh
rainbow="$HOME/Applications/Codex Rainbow.app/Contents/MacOS/rainbow"
"$rainbow" colors
"$rainbow" find "drum"
"$rainbow" set turquoise CHAT_ID
"$rainbow" reset CHAT_ID
```

The palette runs red, orange, yellow, green, turquoise, blue, indigo and violet. New indexed chats continue their folder’s sequence. Overrides update in open Rainbow-launched windows. `reset` restores a chat’s original color. `reset-rainbow` rebuilds each folder’s sequence and clears overrides for unpinned chats, preserving pinned colors.

## How it works

The launcher starts Codex with a private child-process pipe and installs a CSS stylesheet in its local app windows. Each rule selects a chat row by ID. The browser paints the background on the same element that scrolls with the title. The helper refreshes the stylesheet when your color file or chat index changes, when a new window opens, and after a renderer reload. The launcher uses no Accessibility permission, network debugging port or modification to the installed Codex bundle.

Assignments live in `~/Library/Application Support/Codex Rainbow/colors.json`. The helper reads the local chat index and folder metadata. An exported stylesheet contains local chat IDs, so keep it private. The launcher’s status file in the same folder reports the process, styling state and window count. This is an independent macOS integration for local chats. Codex updates that change the renderer, chat index or row attributes may require a Rainbow update.

## Uninstall

Run `./install.sh --uninstall`. It moves the launcher to the Trash, restores a Codex Dock tile it replaced, and keeps your saved colors. Quit and reopen Codex to end the current styling session.

## Development

`./build.sh` builds the row-styling launcher. Use `./build.sh dist/preview --preview` to build the separate read-only chat preview, or `./build.sh dist/overlay --overlay` for the older Accessibility overlay. The overlay uses a separate window and can lag during fast scrolling.

After building, run `python3 Tests/test_cli.py dist/rainbow dist` for assignment and migration tests. On a Mac with Codex installed, `python3 Tests/test_launcher.py "dist/Codex Rainbow.app" dist` exercises two cold starts with an isolated profile and synthetic chat metadata. Run `node Tests/test_renderer.mjs "dist/Codex Rainbow.app" dist` to verify computed fills, a live override, reloads and rapid scrolling on sample rows inside an isolated signed Codex renderer.

[MIT License](LICENSE)
