# WispFlow

macOS menubar dictation: **hold hotkey → recording bubble → OpenAI Whisper → LLM cleanup → paste** into the focused field.

## Install (Terminal)

From a clone:

```bash
./Installer/install.sh
export PATH="$HOME/.local/bin:$PATH"
wispflow setup
wispflow start
```

Or build without installing:

```bash
swift build -c release
./Scripts/package-app.sh release
open .build/WispFlow.app
```

## Usage

1. Grant **Microphone** and **Accessibility** (and **Input Monitoring** if the hotkey does not fire).
2. Hold **Right Option** to record (fallback: set `hotkey = "ctrlShiftSpace"` for Ctrl+Shift+Space).
3. Release → transcript is cleaned and pasted via clipboard + ⌘V.

## CLI

```bash
wispflow setup    # write ~/.config/wispflow/config.toml (chmod 600)
wispflow start    # launch menubar app
wispflow status   # config + permission summary
```

Prefer `OPENAI_API_KEY` in the environment; the file key is a fallback. Optional `base_url` for an OpenAI-compatible gateway (e.g. Vercel AI Gateway).

## Config

```toml
# ~/.config/wispflow/config.toml
openai_api_key = ""
base_url = "https://api.openai.com/v1"
stt_model = "whisper-1"
cleanup_model = "gpt-4o-mini"
hotkey = "rightOption"
```

## Requirements

- macOS 13+
- Swift 5.9+ (Xcode or Command Line Tools)
- OpenAI API key (or compatible gateway)

## License

Private — all rights reserved unless otherwise noted.
