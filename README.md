# WoofTube

A YouTube for iOS build without ads, with tweaks injected into a decrypted YouTube IPA.

Included tweaks:

| Tweak | What it does | License |
|---|---|---|
| [YouTube-X](https://github.com/PoomSmart/YouTube-X) by PoomSmart | Blocks video and feed ads, enables background playback | MIT |
| [YTABGoodies](https://github.com/PoomSmart/YTABGoodies) by PoomSmart | Required by YouTube-X | MIT |

Both are downloaded and compiled from source at build time, using the latest commit.

## Requirements

- Linux on x86_64 or aarch64, with `git curl tar xz perl make python3 unzip`
- A **decrypted** YouTube IPA. An App Store IPA is encrypted and the build stops with an error.
- A sideloading tool to install the result: AltStore, SideStore, Sideloadly, TrollStore or LiveContainer

## Build locally

```bash
scripts/setup-theos.sh
scripts/build-ipa.sh path/to/YouTube.ipa
```

The first command installs Theos, the iOS toolchain and the iOS SDK into `~/theos` (about 1 GB, no sudo). Set `THEOS` to use another folder.

The second command writes `out/WoofTube.ipa`.

To compile the tweaks without an IPA, run `scripts/build-tweaks.sh`. The results go to `.build/dylibs/`.

## Build on GitHub Actions

1. Fork this repository.
2. In **Settings → Secrets and variables → Actions**, add two repository secrets:
   - `IPA_URL`: a direct download link to your decrypted YouTube IPA
   - `IPA_PASSWORD`: a password for the archive the build produces
3. In **Actions → Build IPA**, click **Run workflow**.
4. When the run finishes, download the `WoofTube` artifact from the run page and open `WoofTube.7z` with your `IPA_PASSWORD`.

The IPA is uploaded only inside the encrypted archive and deleted after 3 days. Run logs of a public repository are public, so the URL and password must stay in secrets.

## Known limits

- Signing in may fail on a sideloaded install: sideloaded apps cannot read the keychain group the YouTube login uses. A fix is planned.
- A YouTube update can break a tweak until its author updates it. Rebuilding picks up their latest fixes.
