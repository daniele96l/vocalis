# Vocalis

macOS menubar dictation: **hold hotkey → recording bubble → OpenAI Whisper → LLM cleanup → paste** into the focused field.

## Download (no Terminal / no GitHub setup)

Get the app from the latest release:

**https://github.com/daniele96l/vocalis/releases/latest**

1. Download **Vocalis.dmg** (or `Vocalis.app.zip`).
2. Open it → drag **Vocalis** into **Applications**.
3. First launch: right-click → **Open** once if macOS Gatekeeper warns (ad-hoc signed, not notarized).
4. Grant **Microphone**, **Accessibility**, and **Input Monitoring**.
   - Accessibility: find Vocalis in the list and turn the toggle **On**.
   - Input Monitoring: if Vocalis is missing, click **+** and choose the installed `Vocalis.app`, then toggle **On**. Press any key once in Setup to verify.
5. Paste an OpenAI API key in **Settings** (menubar → Open Vocalis).

Hold **Right Option** to dictate; release to clean up and paste.

Prefer a single install (`~/Applications` via `./Installer/install.sh`, or `/Applications` via the DMG). Multiple copies confuse Microphone / TCC grants.

Direct file: [Vocalis.dmg](https://github.com/daniele96l/vocalis/releases/download/v0.1.1/Vocalis.dmg)

## Install on this Mac (developer)

```bash
./Installer/install.sh
export PATH="$HOME/.local/bin:$PATH"
vocalis start
```

Build a shareable DMG:

```bash
./Scripts/make-dmg.sh
# → dist/Vocalis.dmg  and  dist/Vocalis.app.zip
```

## CLI (optional)

```bash
vocalis setup    # write ~/.config/vocalis/config.toml (chmod 600)
vocalis start    # launch menubar app
vocalis status   # config + permission summary
```

Prefer `OPENAI_API_KEY` in the environment; the file key is a fallback. On first launch Vocalis may also discover a key from common local `.env` files on this machine and save it to config (never bundled into the DMG).

**Never commit API keys.** They live only in `~/.config/vocalis/config.toml` (chmod 600) on each Mac — not in git, not in the DMG. `Scripts/check-no-secrets.sh` runs during DMG packaging.

Legacy `~/.config/wispflow/config.toml` is migrated automatically on first load.

## Config

```toml
# ~/.config/vocalis/config.toml
openai_api_key = ""
base_url = "https://api.openai.com/v1"
stt_model = "whisper-1"
cleanup_model = "gpt-4o-mini"
hotkey = "rightOption"
```

## Requirements

- macOS 13+
- OpenAI API key (or compatible gateway)
- Swift 5.9+ only needed to build from source

## License

Private — all rights reserved unless otherwise noted.
