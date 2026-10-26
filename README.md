# ScreenOCR

**Grab any text on your screen with a shortcut, and paste it anywhere. Made for people who work in SSH sessions and terminal tools like Claude Code.**

Press a shortcut, drag a box over some text, and the text is copied to your clipboard. ScreenOCR has two modes:

- **Fast mode** uses the OCR engine built into Windows. It takes about a second and everything stays on your PC.
- **Exact mode** has Claude read the text through your **Claude Code subscription**. It takes about 6–10 seconds, needs no API key, and has no per-grab cost.

## The problem it solves

If you work in a remote terminal on Windows (SSH, WSL, tmux, Claude Code running on a server), copying and pasting gets painful:

- **You can't paste images into a remote Claude Code session.** The clipboard is on your PC, and Claude Code is on the server.
- **Copying from terminal apps is fiddly.** Text in full-screen tools like Claude Code, tmux or vim is often hard to select, or it copies with broken line wraps.
- **Some text can't be selected at all.** For example, text inside a screenshot, a remote desktop window, a video, or a locked-down app.

ScreenOCR works around all of these. If you can see the text, you can grab it as real text, then paste it into your terminal like anything else.

## How it works

1. Press **Ctrl+Alt+L** (fast) or **Ctrl+Alt+Shift+L** (exact).
2. The screen freezes and dims. Drag a box around the text you want.
3. The text is now on your clipboard, and a notification shows what was copied.
4. Paste it into your terminal (in Windows Terminal: **Ctrl+Shift+V** or right-click).

Press **Esc** or right-click to cancel a grab. You can also left-click the tray icon (blue **"Aa"**) for a fast grab, or right-click it to pick either mode.

## Which mode should I use?

|                   | Fast: **Ctrl+Alt+L**              | Exact: **Ctrl+Alt+Shift+L**                  |
|-------------------|-----------------------------------|----------------------------------------------|
| Engine            | Windows' built-in OCR             | Claude (Sonnet) through `claude -p`          |
| Speed             | about 1 second                    | about 6–10 seconds                           |
| Accuracy          | good on prose and tables, often wrong on commands | exact in all our tests, including commands, hashes and keys |
| Privacy           | never leaves your PC              | the grabbed image is sent to Anthropic       |
| Cost              | free                              | counts toward your Claude plan's usage limits |

**Rule of thumb:** use **exact mode for commands** you're going to run, and fast mode for everything else.

In our tests, the fast mode got 27% of shell commands exactly right (about 91% of individual characters). That's because one wrong character breaks a command. It often confuses `l`, `1`, `I` and `|`, mixes up `0`, `O` and `@`, and sometimes drops long random strings like hashes or API keys. ScreenOCR fixes the most common of these mistakes automatically, but not all of them. The exact mode got every test command right.

## Requirements

- **Windows 10 or 11.** Nothing to install for the fast mode.
- **For exact mode:** [Claude Code](https://code.claude.com) installed and logged in **inside WSL** (your default WSL distro). Check by running `claude -p "say hi"` in WSL. It should answer without asking you to log in.

## Install

1. Download this repo: **Code → Download ZIP**, or clone it.
2. Put the folder somewhere on your Windows drive, e.g. `C:\Users\<you>\ScreenOCR`. Don't run it from a `\\wsl$\...` path.
3. Double-click **`ScreenOCR.vbs`**. A blue **"Aa"** icon appears in the system tray, and a notification confirms the shortcuts.
4. Optional: right-click the tray icon and tick **"Start with Windows"** so it runs every time you log in.

If Windows warns you about the file the first time you run it, choose **More info → Run anyway**. The only files that run are `ScreenOCR.vbs` and `ScreenOCR.ps1`, and both are short and readable.

To stop it, right-click the tray icon and choose **Exit**.

## Changing the shortcuts or model

Edit the `param(...)` block at the top of `ScreenOCR.ps1`:

```powershell
[string]$Hotkey = 'Ctrl+Alt+L',               # fast mode
[string]$ClaudeHotkey = 'Ctrl+Alt+Shift+L',   # exact mode
[string]$ClaudeModel = 'sonnet'               # or 'haiku' (lighter on usage, slightly less exact)
```

Then exit and restart ScreenOCR. A shortcut can combine `Ctrl`, `Alt`, `Shift` and `Win` with a key, e.g. `'Win+Shift+O'`.

If a shortcut is already taken by another program, ScreenOCR tells you on startup. You can still use the tray menu.

## Tips for terminal users

- **Copying from Windows Terminal without ScreenOCR:** hold **Shift while dragging** to select text even when a program like Claude Code, tmux or vim is capturing the mouse. Then press **Ctrl+Shift+C** to copy.
- **Real images** (diagrams, UI screenshots): OCR only gets the text. If you need Claude to see the actual image, copy the image file to the server and give Claude Code its path instead.
- **Tables and box-drawing characters** come through in exact mode. Column padding may be slightly uneven, but all the text is there.

## Troubleshooting

**Pressing the shortcut types a letter like `Ó` instead of grabbing.** ScreenOCR isn't running, or it couldn't register that shortcut. On some keyboard layouts, Ctrl+Alt works like AltGr and types accented letters. Check the tray icon is there, or start `ScreenOCR.vbs` again.

**"ScreenOCR (Claude) error" notification.** The message is Claude Code's own error. The usual causes:
- Claude Code isn't installed in your default WSL distro.
- You're logged out. Run `claude` in WSL once to log in.
- You've hit your plan's usage limit.

**Fast mode gets something wrong.** Use exact mode for that grab.

**The selection box doesn't line up with the screen (multi-monitor or display scaling).** Please open an issue with your monitor setup.

## How it works under the hood

- **One PowerShell script, no install.** It uses WinForms for the tray icon, the selection overlay and the global hotkeys.
- **Fast mode** uses `Windows.Media.Ocr`, the same engine behind PowerToys Text Extractor. Before reading, it:
  1. upscales the image;
  2. stretches the contrast so terminal colors (green on black, grey on blue...) become clean black on white;
  3. reads the image at two zoom levels and keeps the better result.

  After reading, it rebuilds rows and columns from the word positions, so tables and indented code keep their layout. Then it fixes common command mistakes, for example `Is` → `ls`, `I` → `|`, `N/` → `~/`, `2>1` → `2>&1` and typographic dashes → `-`.
- **Exact mode** saves the grab to `%LOCALAPPDATA%\ScreenOCR\grab.png`. It then runs `claude -p` inside WSL and asks Claude to transcribe the image exactly. `claude -p` is Claude Code's official non-interactive mode, so it uses your normal subscription login. ScreenOCR never reads or handles your credentials.

## Testing

`tests/Test-ScreenOCR.ps1` checks the fast mode. It renders 34 realistic shell commands in 9 terminal styles (different fonts, sizes and color schemes, light and dark) and reports how many come back exactly right:

```powershell
powershell -STA -ExecutionPolicy Bypass -File tests\Test-ScreenOCR.ps1 -ShowFailures
```

You can also OCR an image file from the command line:

```powershell
powershell -ExecutionPolicy Bypass -File ScreenOCR.ps1 -OcrFile screenshot.png           # fast mode
powershell -ExecutionPolicy Bypass -File ScreenOCR.ps1 -OcrFile screenshot.png -Claude   # exact mode
```

## License

MIT. See [LICENSE](LICENSE).
