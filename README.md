# Vocalis

macOS menubar dictation: **hold hotkey → recording bubble → speech-to-text → optional cleanup → paste** into the focused field.

**Public repo:** https://github.com/daniele96l/vocalis

---

## Which install should I use?

| Goal | What you need | How |
|------|----------------|-----|
| Just run Vocalis | Nothing (no Xcode) | [Download a release](#download-no-xcode--recommended) |
| Update an old install | Nothing | [Update](#update) |
| Build from source | **Command Line Tools** only (not full Xcode) | [Build from source](#build-from-source-no-full-xcode) |

**main vs Releases:** GitHub `main` is always the newest source. [Releases](https://github.com/daniele96l/vocalis/releases) ship pre-built `.dmg` / `.zip` — use those if you don’t want to compile. If the app feels “old”, you probably installed an older Release; update with the steps below.

---

## Download (no Xcode) — recommended

Pre-built app. **No Xcode, no Swift, no git.**

**https://github.com/daniele96l/vocalis/releases/latest**

1. Download **Vocalis.dmg** or **Vocalis.app.zip**.
2. Open → drag **Vocalis** into **Applications** (or `~/Applications`).
3. First launch: right-click → **Open** once if Gatekeeper warns (ad-hoc signed, not notarized).
4. Grant **Microphone**, **Accessibility**, and **Input Monitoring**.
5. Open Vocalis → **Account**: activate a **license code** (friends) **or** paste your own OpenAI / xAI keys.

Or one command (downloads the latest zip from Releases):

```bash
curl -fsSL https://raw.githubusercontent.com/daniele96l/vocalis/main/Scripts/install-release.sh | bash
```

Hold **Right Option** to dictate; release to clean up and paste.

Prefer **one** install path only. Multiple copies confuse Mic / Accessibility / Input Monitoring grants.

---

## Update

### Pre-built (no Xcode)

```bash
curl -fsSL https://raw.githubusercontent.com/daniele96l/vocalis/main/Scripts/install-release.sh | bash
```

Or download the newest DMG/zip from [releases/latest](https://github.com/daniele96l/vocalis/releases/latest) and replace the old app.

Check version: menubar → Open Vocalis → Home, or:

```bash
defaults read ~/Applications/Vocalis.app/Contents/Info CFBundleShortVersionString
# or: defaults read /Applications/Vocalis.app/Contents/Info CFBundleShortVersionString
```

### Built from source earlier

Re-run the installer (it resets the cache clone to `origin/main`):

```bash
curl -fsSL https://raw.githubusercontent.com/daniele96l/vocalis/main/Installer/install.sh | bash
```

Or if you already have a checkout:

```bash
cd ~/vocalis   # or wherever you cloned
git pull origin main
./Installer/install.sh
```

If an old cache is stuck: `rm -rf ~/.cache/vocalis/src` then install again.

---

## Build from source (no full Xcode)

You do **not** need the full Xcode app (~10+ GB). The smaller **Apple Command Line Tools** package is enough (includes `swift` + `git`).

```bash
xcode-select --install          # once; ~1 GB, not full Xcode
git clone https://github.com/daniele96l/vocalis.git ~/vocalis
cd ~/vocalis
./Installer/install.sh
export PATH="$HOME/.local/bin:$PATH"
vocalis start
```

This builds from **current `main`**, installs to `~/Applications/Vocalis.app`, and adds `~/.local/bin/vocalis`.

Build a shareable DMG (for publishing a Release):

```bash
./Scripts/make-dmg.sh
# → dist/Vocalis.dmg  and  dist/Vocalis.app.zip
```

---

## CLI (optional)

```bash
vocalis setup    # write ~/.config/vocalis/config.toml (chmod 600)
vocalis start    # launch menubar app
vocalis status   # config + permission summary
```

Prefer `OPENAI_API_KEY` in the environment; the file key is a fallback. On first launch Vocalis may also discover a key from common local `.env` files on this machine and save it to config (never bundled into the DMG).

**License (friends):** enter a `VOC-…` code in **Account**. Traffic goes through a small Cloudflare Worker ([`workers/vocalis-proxy`](workers/vocalis-proxy)) that holds your provider keys. Same code works on multiple Macs. License wins if both a code and local keys are set.

Mint codes (local ledger, **gitignored** — never on GitHub):

```bash
./Scripts/mint-licenses.sh 10
# copy the comma-separated list into: cd workers/vocalis-proxy && npx wrangler secret put LICENSE_CODES
```

See [`workers/vocalis-proxy/README.md`](workers/vocalis-proxy/README.md) to deploy the proxy.

**Never commit API keys or license ledgers.** Keys live in `~/.config/vocalis/config.toml` (chmod 600); codes in `licenses.json` (gitignored). `Scripts/check-no-secrets.sh` runs during DMG packaging.

If paste fails (e.g. Accessibility off), the text stays on the **clipboard** and is written to `~/.config/vocalis/last_dictation.txt` (full history in `dictations.log`). Press ⌘V to recover.

Legacy `~/.config/wispflow/config.toml` is migrated automatically on first load.

---

## Config

```toml
# ~/.config/vocalis/config.toml
openai_api_key = ""
xai_api_key = ""
license_code = ""
license_proxy_url = "https://vocalis-proxy.daniele96l.workers.dev"
base_url = "https://api.openai.com/v1"
stt_model = "whisper-1"
cleanup_model = "gpt-4o-mini"
hotkey = "rightOption"
```

---

## Requirements

- macOS 13+
- A Vocalis license code **or** your own OpenAI / xAI API keys
- To **run** a Release build: nothing else
- To **build** from source: Command Line Tools (`xcode-select --install`) — full Xcode optional

## License

All rights reserved unless otherwise noted.
