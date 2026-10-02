# LM Studio Status Widget

Native macOS widget-style app for checking a local LM Studio server.

It shows:

- whether the LM Studio server responds
- currently loaded models
- active token generation (`GEN`), observed duration, and queued requests
- the endpoint used for the latest successful check

Requirements:

- macOS 15 or newer
- Xcode with a macOS 15 SDK or newer
- LM Studio local server on port `1234`

Default server URL:

```text
http://localhost:1234
```

## Install with Homebrew

On Apple Silicon Macs running macOS 15 or newer, install the signed and notarized app with:

```bash
brew install --cask r3d42-git/tap/lm-studio-status-widget
```

The [Homebrew tap](https://github.com/r3d42-git/homebrew-tap) tracks the latest published GitHub
release. LM Studio still needs to be installed and its local server needs to be running.

Run locally:

```bash
./script/build_and_run.sh
```

Run the parser tests:

```bash
swift test
```

## Release workflow

Development builds created by `script/build_and_run.sh` are ad-hoc signed and are not release artifacts.
Official releases are built, Developer ID signed, notarized, stapled, and verified locally before anything
is uploaded to GitHub.

Local prerequisites:

- the Developer ID Application identity in the login Keychain
- the `notarytool` Keychain profile `LMStudioStatusWidget-notary`
- GitHub CLI authentication for the separate publish step

Create and verify a local release without publishing it:

```bash
./script/release.sh 1.2.1
```

This produces the final ZIP, a SHA-256 file, the original notarization submission, and the Apple notary
result/log below `dist/`. Review the result before publishing.

Publishing is intentionally separate and requires a clean `main` worktree. It creates and pushes the version
tag, publishes the GitHub release, downloads the asset again, and re-verifies the downloaded app:

```bash
./script/publish_release.sh 1.2.1 RELEASE_NOTES/1.2.1.md
```

Omit the notes file to use GitHub-generated release notes. Validate everything locally without changing Git or
GitHub by using:

```bash
./script/publish_release.sh --dry-run 1.2.1
```

GitHub Actions runs `swift test` and `swift build -c release` for pushes and pull requests. Signing and
notarization stay local, so no Apple certificate or notarization secrets are stored on GitHub.

Starting with v1.2.1, the source and packaged app use `GPL-3.0-or-later`. The full GPLv3 text,
licensing notice, and preserved historical MIT notice are included in the app. Earlier releases
retain their MIT license. The release and publish scripts verify these files in the packaged app.

The app polls `/api/v1/models` first and falls back to the OpenAI-compatible `/v1/models` endpoint.
For a local server it also reads the supported `lms ps --json` runtime status. LM Studio does not expose
another client's exact live token count through this interface, so the widget shows the exact generation
state and how long it has observed it instead of estimating a misleading token number.

## Privacy

The app communicates only with the LM Studio server URL configured by the user.
It contains no analytics, telemetry, advertising, or bundled credentials.

## License and credits

Starting with v1.2.1, this project is licensed under [GPL-3.0-or-later](LICENSE).
The original MIT license and 2026 R3D42 copyright notice remain in
[LICENSE-MIT](LICENSE-MIT) for the earlier releases. See [LICENSING.md](LICENSING.md).
