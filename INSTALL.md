# Installing Ticker Evaluator from this repo

Ticker Evaluator isn't on the App Store. You build it on your own Mac from the source code, which takes a few minutes the first time.

## What you need
- **macOS 26** or later.
- **Xcode 26** or later: free from the Mac App Store. After installing it, **open Xcode once** so it can finish setting up, then quit it.
- About 5 GB of free space for Xcode, and an internet connection.

## Steps

**1. Open Terminal** (Applications → Utilities → Terminal).

**2. Download the code** (into a folder called `investment-research-tool` in your home folder):

```bash
git clone https://github.com/ilfir/investment-research-tool.git ~/investment-research-tool
```

If macOS asks to install the command-line developer tools, click **Install**, wait for it to finish, then run the command again.

**3. Build and install:**

```bash
cd ~/investment-research-tool && ./scripts/install.sh
```

This builds the app and copies it to **/Applications**, then opens it. If your account can't write to /Applications, it asks for your password.

**4. Done.** Open **Ticker Evaluator** from Applications, Launchpad or Spotlight like any other app. See [README.md](README.md#how-to-use) for how to use it.

## Updating to a newer version

```bash
cd ~/investment-research-tool && git pull && ./scripts/install.sh
```

Your positions, profile, answers and settings are kept. They live outside the app, in `~/Library/Application Support/TickerEvaluator/`.

## Options
- Install somewhere else: `DEST=~/Applications ./scripts/install.sh`
- Run the tests before installing: `./scripts/install.sh --test`

## Uninstalling

```bash
rm -rf /Applications/TickerEvaluator.app
rm -rf ~/Library/Application\ Support/TickerEvaluator   # also deletes your saved positions and settings
```

## Troubleshooting

| Message | Fix |
|---|---|
| `xcode-select: error: tool 'xcodebuild' requires Xcode` or the script says the tools "point at CommandLineTools" | Run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`, then try again. |
| `You have not agreed to the Xcode license` | Run `sudo xcodebuild -license accept`, or open Xcode once and accept. |
| `permission denied: ./scripts/install.sh` | Run `chmod +x scripts/install.sh` and try again. |
| The app opens but shows "Couldn't evaluate" | Check your internet connection. The data sources are free public services that are occasionally slow or down, so try again in a minute or use **Fetch fresh** (⌘R). |

The app is signed locally on your Mac (ad-hoc), not by a registered developer. Because you built it yourself, macOS opens it without a warning.
