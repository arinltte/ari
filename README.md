<p align="center">
  <img src="public/logo.jpg" alt="ari Logo" width="64" />
  <br />
  <h1 align="center">ari</h1>
  <p align="center">The Quiet AI on Your Mac</p>
  <p align="center">
    <a href="https://github.com/arinltte/ari/releases/latest"><img src="https://img.shields.io/github/v/release/arinltte/ari?style=flat-square&color=blue" alt="Latest Release" /></a>
    <a href="https://github.com/arinltte/ari/blob/main/LICENSE"><img src="https://img.shields.io/github/license/arinltte/ari?style=flat-square&color=green" alt="License" /></a>
    <img src="https://img.shields.io/badge/python-3.10%2B-blue?style=flat-square" alt="Python" />
    <img src="https://img.shields.io/badge/app%20memory-%3C50MB-brightgreen?style=flat-square" alt="Memory" />
  </p>
</p>

---

ari is a lightweight, open-source AI launcher for macOS that lives entirely in the menu bar. It runs local language models on-device using MLX, giving you instant AI access from anywhere on your Mac — no browser, no cloud, no background services you didn't ask for.

<video src="https://github.com/user-attachments/assets/8fe6b7fd-83ed-4395-b5e4-8bf11acd0ff2" controls width="800"></video>

> [!TIP]
> ari itself uses **under 50 MB of memory**.

---

## 🏗️ Features

- **Menu bar native** — ari lives in your menu bar and appears on demand. No Dock icon, no persistent window, no interruption to your workflow.
- **Fully local and private** — All inference runs on-device via MLX. Your prompts never leave your machine.
- **Ultralight footprint** — The ari app itself runs in under 50 MB of memory. Only the MLX model server uses additional memory, proportional to the model size you choose.
- **Minimal resource usage** — Idle timeout shuts down the model server automatically and restarts it transparently on next use.
- **Fast startup** — Models are loaded once and kept warm in the background, ready the moment you need them.
- **Streaming responses** — Output streams token by token in real time, with full Markdown and LaTeX rendering once generation completes.
- **Model management built in** — Download any compatible model directly from Hugging Face, switch between models, and delete them all from within the app.
- **Customisable menu bar icon** — Choose from a set of SF Symbols to match your aesthetic.

---

## Requirements

- macOS 14 (Sonoma) or later
- Python 3.10 or later — install via [python.org](https://www.python.org/downloads/) or `brew install python@3.12`
- Apple Silicon (M1 or later) recommended

---

## 🚀 Installation

### Recommended

Download the latest `.dmg` from the [Releases](https://github.com/arinltte/ari/releases/latest) page, open it, and drag **ari** to your Applications folder.

### Gatekeeper

If macOS blocks the app on first launch, run the following in Terminal after installation:

```bash
xattr -rd com.apple.quarantine /Applications/ari.app
```

> **Note:** Your Terminal application may require **Full Disk Access** before this command works.
> Grant it under **System Settings → Privacy & Security → Full Disk Access**, then run the command above.

Afterward, open **System Settings → Privacy & Security** and grant the following permissions when prompted:

- **Accessibility**
- **Screen Recording**

Once permissions are granted, launch ari normally from your Applications folder.

### First Launch

On first launch, ari will automatically set up a self-contained Python virtual environment at `~/.ari/Python` and install all required dependencies (`mlx-lm`, `mlx-vlm`, `torch`, `torchvision`, `huggingface_hub`). This takes a few minutes and only happens once.

After setup, go to **Settings → Download from Hugging Face** and enter any compatible MLX model repository.

---

## Getting Started

1. Click the ari icon in your menu bar.
2. Go to **Settings** and download a model from Hugging Face.
3. ari loads the selected model and streams the response directly in the panel.
4. Type your question in the input field and press **Return**.
5. Press **Escape** to dismiss the panel at any time.

---

## 🤖 Recommended Models

ari works with any MLX-compatible model. For the best performance on Apple Silicon, use models from the **[mlx-community](https://huggingface.co/mlx-community/models)** organisation on Hugging Face — these are pre-converted and optimised specifically for MLX.

**Good starting points:**

| Model | Size | Use Case |
| --- | --- | --- |
| `mlx-community/Qwen3.5-2B-MLX-4bit` | ~1.75 GB | Fast, everyday queries |
| `mlx-community/gemma-4-e4b-it-4bit` | ~5.25 GB | Balanced quality and speed |

> Browse the full catalogue at [huggingface.co/mlx-community/models](https://huggingface.co/mlx-community/models).

---

## Limitations

- Python 3.10 or later must be installed before launching ari for the first time
- If Python is missing or outdated, ari will display instructions and pause setup until it is resolved
- Accessibility and Screen Recording permissions are required for full functionality.
- Model loading time depends on model size and available unified memory.
- Vision model support requires `torch` and `torchvision`, which are installed automatically during setup.

---

## 📂 Data & Privacy

ari stores the following data locally on your machine and nowhere else:

| Location | Contents |
| --- | --- |
| `~/.ari/` | Python environment, downloaded models, cache |
| `~/Library/Preferences/com.arinltte.ari.plist` | App preferences (selected model, icon, timeout) |

No usage data, prompts, or telemetry of any kind are transmitted externally.

To perform a complete uninstall and remove all application data:

```bash
lsof -ti:8080 | xargs kill -9 2>/dev/null || true
rm -rf ~/.ari
rm -rf ~/.cache/huggingface
rm -f ~/Library/Preferences/com.arinltte.ari.plist
rm -rf ~/Library/Application\ Support/com.arinltte.ari 2>/dev/null
rm -rf ~/Library/Saved\ Application\ State/com.arinltte.ari.savedState 2>/dev/null
killall cfprefsd
```

---

## 🤝 Contributing

Contributions are welcome. Whether it's a bug report, a feature suggestion, a documentation improvement, or a pull request — all are appreciated.

**To contribute:**

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/your-feature-name`
3. Commit your changes with a clear message.
4. Open a pull request against `main` with a description of what you changed and why.

**To report a bug or request a feature**, open an [issue](https://github.com/arinltte/ari/issues) and use the appropriate template. Please include your macOS version, Apple Silicon chip model, and steps to reproduce for bug reports.

All contributions are expected to follow basic open-source etiquette: be respectful, be specific, and be patient.

---

## Building from Source

```bash
git clone https://github.com/arinltte/ari.git
cd ari
open ari.xcodeproj
```

Build and run the `ari` scheme in Xcode. Requires Xcode 16 or later.

Dependencies are managed via Swift Package Manager and will resolve automatically on first build:

- [SwiftMath](https://github.com/mgriebling/SwiftMath) — LaTeX math rendering

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

<p align="center">
  <i>Developed by arinltte · cjshen00@gmail.com</i>
</p>
