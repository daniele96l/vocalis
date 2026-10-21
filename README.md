# Vocalis

macOS menubar dictation: **hold hotkey → recording bubble → OpenAI Whisper → LLM cleanup → paste** into the focused field.

## Install for someone else (no Terminal)

1. Open `dist/Vocalis.dmg` (or `Vocalis.app.zip`).
2. Drag **Vocalis** into **Applications**.
3. First launch: right-click → **Open** once if macOS Gatekeeper warns (ad-hoc signed, not notarized).
4. Grant **Microphone** + **Accessibility** (+ **Input Monitoring** if the hotkey does nothing).
5. If no API key is configured yet, paste one in **Settings…** from the menubar icon.

Hold **Right Option** to dictate; release to clean up and paste.

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
