# Codex Limit Banner Hider

[简体中文](README.md)

An unofficial, user-level macOS customization that hides the blocking “Codex / Work usage exhausted” banner and releases its layout space.

It does **not** increase, restore, or bypass usage limits. It never clicks purchase or reset actions, edits the signed app bundle, re-signs Codex, changes account data, or exposes a remote-debugging TCP port.

## How it works

A per-user LaunchAgent watches for a freshly launched, officially signed Codex process. It verifies the app path, bundle identifier, OpenAI Team ID, deep code signature, PID/start identity, exact main page, and a strict allowlist of banner text, structure, and actions. It then launches the original app with a private `--remote-debugging-pipe` and injects a fail-closed DOM observer.

Only one uniquely qualified banner is marked and hidden. Unknown structures, actions, or multiple candidates remain visible.

This is a community project, not an OpenAI feature and not supported by OpenAI.

## Requirements

- macOS;
- Codex installed at `/Applications/ChatGPT.app`;
- Xcode Command Line Tools (`swiftc`);
- permission to install a per-user LaunchAgent.

## Install

```zsh
git clone https://github.com/DavidLam-oss/codex-limit-banner-hider.git
cd codex-limit-banner-hider
./install.sh
```

Installation preserves the currently running Codex PID. Quit normally with `⌘Q` when no task is running, then reopen Codex. A successful active state reports `mode: managed` with `decision: absent` or `hidden`.

```zsh
./status.sh --json
```

Codex updates do not overwrite this project. Every new process is reverified. Compatible UI versions are handled automatically; incompatible DOM changes fail closed.

## Test

```zsh
./test/run.sh
```

The local integration tests use an isolated temporary profile and cover the private CDP pipe plus ten target/non-target DOM cases. No test clicks a banner action.

## Uninstall

```zsh
./uninstall.sh
```

Installed files are moved to Trash. A currently running Codex process is not force-quit.

See [SECURITY.md](SECURITY.md) for the security model and reporting guidance.

## License

[MIT](LICENSE)
