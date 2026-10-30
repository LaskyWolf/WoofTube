# WoofTube native app

A SwiftUI YouTube client. It contains no YouTube code and needs no decrypted IPA.

See [ROADMAP.md](ROADMAP.md) for what exists and what is missing.

## Build

Building needs Xcode 26. Linux users can use the `Native app` GitHub Actions workflow, which produces an unsigned IPA that lasts one day.

On a Mac:

```bash
brew install xcodegen
cd app
xcodegen generate
open WoofTube.xcodeproj
```

## Account risk

Google can challenge or restrict an account used in an unofficial app, and posting comments is more visible than watching. Test with a second account.

## License

GPL-3.0, because it uses [SwiftyTube](https://github.com/686udjie/SwiftyTube) and code from [Trop](https://github.com/686udjie/Trop).
