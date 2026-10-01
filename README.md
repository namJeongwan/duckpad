# Duckpad

<p align="center">
  <img src="docs/assets/duckpad.png" alt="Duckpad" width="240">
</p>

Duckpad is a text and code editor for macOS, inspired by [Notepad++](https://github.com/notepad-plus-plus/notepad-plus-plus).

It brings familiar text editing to the Mac with native menus, multiple document tabs, split editor groups, syntax highlighting, search and replace, and document comparison.

![Duckpad showing multiple document tabs and duck ASCII art](docs/assets/duckpad-screenshot.png)

[Website](https://namjeongwan.github.io/duckpad/) · [한국어](https://namjeongwan.github.io/duckpad/ko/)

## Download

[Download Duckpad](https://github.com/namJeongwan/duckpad/releases/latest)

Requires macOS 13 or later. Supports Apple Silicon and Intel Macs.

This early release is not notarized by Apple. See the release notes for installation instructions.

## Terminal

Duckpad automatically installs the `duckpad` command on the first launch after
installation or an update. Open a new terminal window, then run:

```sh
duckpad .
duckpad test.txt
duckpad a.txt b.txt
```

Folders open in the workspace sidebar; existing files open in editor tabs.
An already running Duckpad receives the request in its active window.

The command lives in `~/.local/bin`. Duckpad appends a PATH entry to `.zprofile`
and `.bash_profile` for zsh and bash without replacing existing settings or
another `duckpad` command. Existing commands on PATH retain priority. Custom
startup locations (including `ZDOTDIR`) and other shells need `~/.local/bin` on their PATH.
To uninstall the command, remove `~/.local/bin/duckpad`; the PATH entry can stay
if other programs use that directory.

## Development

Requires macOS and Xcode Command Line Tools with Swift 6 or later. Run the commands below from the repository root.

```sh
swift run DuckpadApp
```

## Build

Create a universal `.app` for Apple Silicon and Intel Macs:

```sh
scripts/build_macos_app.sh --output build/Duckpad.app
```

Add `--architecture native` to build only for your Mac. The output path must not already exist. The default build uses ad-hoc signing without Apple notarization.

## Languages

- [ ] English
- [ ] Korean
- [ ] Japanese
- [ ] Chinese (Simplified)
- [ ] Portuguese (Brazil)
- [ ] Italian
- [ ] French
- [ ] German
