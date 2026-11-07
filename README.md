# YumeFlix

<div align="center">
  <a href="https://github.com/akashdh11/skystream/releases">
    <img src="https://img.shields.io/github/downloads/akashdh11/skystream/total?style=for-the-badge&color=1f6feb" />
  </a>
  <a href="https://github.com/akashdh11/skystream/stargazers">
    <img src="https://img.shields.io/github/stars/akashdh11/skystream?style=for-the-badge&color=f1c40f" />
  </a>
  <a href="https://github.com/akashdh11/skystream/releases">
    <img src="https://img.shields.io/github/v/release/akashdh11/skystream?style=for-the-badge&color=f39c12" />
  </a>
  <a href="https://github.com/akashdh11/skystream/issues">
    <img src="https://img.shields.io/github/issues/akashdh11/skystream?style=for-the-badge&color=e74c3c" />
  </a>
  <a href="https://github.com/akashdh11/skystream/issues?q=is%3Aissue+is%3Aclosed">
    <img src="https://img.shields.io/github/issues-search/akashdh11/skystream?query=is%3Aissue+is%3Aclosed&style=for-the-badge&color=2ecc71" />
  </a>
  <a href="https://github.com/akashdh11/skystream/commits/main">
    <img src="https://img.shields.io/github/last-commit/akashdh11/skystream?style=for-the-badge&color=17a2b8" />
  </a>
</div>



**⚠️ Warning: By default, this app doesn't provide any video sources; you have to install extensions to add functionality to the app.**

On first launch, YumeFlix can add the default extension repository for browsing, but it does not automatically install executable third-party extensions. If an installed provider is named exactly **4K HD**, YumeFlix selects it only when you have not previously chosen a provider. The label is a provider name—not a guarantee that every title or device will have a 4K stream. Your saved provider choice, including **None**, is respected.

**A polished, phone-first cross-platform media streaming application built with Flutter.**

> **Note**: This project is an independent application built with Flutter. While it supports similar extension formats, it is a simplified, modern re-imagining and is **not** a direct clone or fork of the official client.

**Please don't create illegal extensions or use any that host any copyrighted media.** This project does not condone copyright infringement.

## Community

Join the discussion, get help, or find new extensions on our Telegram channel or Discord server:

<a href="https://t.me/+Ez5Vsv2pUUFjZmNl">
  <img src="https://img.shields.io/badge/Telegram-Channel-blue?style=for-the-badge&logo=telegram">
</a>

<br>


<a href="https://discord.gg/73XGA8Mxn9">
  <img src="https://invidget.switchblade.xyz/73XGA8Mxn9">
</a>


## Overview

YumeFlix is a modern media streaming client. It implements a custom, cross-platform JavaScript engine for extensions, enabling support for Android phones, iOS, and desktop from a single codebase.

### Built With

![Flutter](https://img.shields.io/badge/Flutter-%2302569B.svg?style=for-the-badge&logo=Flutter&logoColor=white) ![Dart](https://img.shields.io/badge/dart-%230175C2.svg?style=for-the-badge&logo=dart&logoColor=white) ![Riverpod](https://img.shields.io/badge/Riverpod-%232D3748.svg?style=for-the-badge&logo=riverpod&logoColor=white) ![Hive](https://img.shields.io/badge/Hive-%23DE3027.svg?style=for-the-badge&logo=hive&logoColor=white)

### Screenshots

### 📱 Mobile

<p align="center">
  <img src="screenshots/mobile/home.png" width="360" />
    <img src="screenshots/mobile/discover.png" width="360" />
  <img src="screenshots/mobile/details.png" width="360" />
  <img src="screenshots/mobile/settings.png" width="360" />
</p>

## Supported Platforms

The supplied APK targets touch-screen Android phones. Android TV/Leanback
launcher support is intentionally not included in this release. APKs are split
by ARM processor architecture to keep each download smaller.

## ✨ Features

💡 **YumeFlix** is a phone-first, plugin-driven streaming client for Android.

### 🔎 Powerful Search & Discovery
- 🔍 **Plugin-wise Search** – Search within specific providers for more accurate results  
- 💡 **Smart Search Suggestions** – Get real-time suggestions while typing  
- 🌐 **Advanced Discovery (TMDB Integration)** – Explore trending, popular, and filtered content  
- 🎯 **Custom Home Experience** – Set Explore as your default landing screen  
- 🌍 **Multi-language Filtering** – Discover content across 40+ languages

### 🎬 Advanced Streaming Experience
- 📺 **Live Streaming Support** – Watch live content with improved reliability  
- ▶️ **Resume Playback** – Continue watching from where you left off  
- ⏩ **Playback Speed Control** – Adjust speed to your preference  
- 🎚️ **Default Quality Selection** – Set preferred streaming quality  
- 📑 **Episode Overlay** – Browse and switch episodes inside the player  
- 🔍 **Detailed Loading Insights** – View source details while content loads

### 🔗 Integrations & Tracking
- 🔄 **Multi-Tracker Sync** – Keep your watch list and progress synchronized across **Trakt**, **Simkl**, **MyAnimeList (MAL)**, and **AniList**
- ⏭️ **Smart Skip (Intro/Outro)** – Seamlessly skip intro and outro sequences using **IntroDB** and **Anime Skip** integration

### 🌐 Multi-Provider & Plugin System
- 🔌 **Plugin-Based Architecture** – Extend functionality with custom plugins  
- 🔁 **Multi-Provider Support** – Access multiple content sources within a single plugin  
- 🌍 **Domain Switching** – Switch domains seamlessly for better availability  
- 🪵 **In-App Logs (Developer Tools)** – Debug plugins directly inside the app

### 💬 Subtitles & Content Flexibility
- 🌍 **External Subtitles Support** – Integrated with:
  - OpenSubtitles  
  - SubDL  
  - Subsource  
- 📝 **Subtitle Styling** – Customizable font size and colors

### 📥 Offline & External Playback
- ⬇️ **Download Content** – Watch offline anytime  
- 🎥 **External Player Support** – Play content in your preferred media player

### 📱 Android Phone Build
- Touch-screen Android phone launcher; no Leanback/Android TV launcher entry
- Separate ARM64 and ARMv7 APKs for smaller downloads and broad phone coverage

### ⚡ Performance & Reliability
- 🚀 **Optimized Performance** – Faster load times and smoother UI  
- 🧠 **New JavaScript Engine (`quick_js_ng`)** – Better execution and compatibility  
- 🌐 **DNS over HTTPS** – Encrypted DNS option for privacy on supported networks  
- 📉 **Reduced App Size** – Lightweight and efficient  
- 🔧 **Stability Improvements** – Enhanced reliability across all platforms

### 🎨 Modern UI/UX
- 🎨 **Clean & Modern Interface** – Redesigned Home and Details screens  
- 🧭 **Improved Navigation** – Explore-based content discovery  
- 🌗 **Theme Improvements** – Better light mode and UI consistency  

### 🌍 Global Accessibility
- 🌐 **40+ Language Support** – Fully localized experience  
- 🎯 **Region-aware Discovery** – Content tailored to global audiences

## 📥 Installation

Download the latest version from the **[Releases Page](https://github.com/akashdh11/skystream/releases/latest)**.

### 🤖 Android phones
1. Download the universal ARM APK for current 64-bit and legacy 32-bit ARM phones. It contains both ARM runtimes in one file.
2. Open the file and tap **Install**.
   - *Note: You may need to allow "Install from Unknown Sources" in your browser settings.*
3. Open YumeFlix and install extensions via **Settings > Extensions**.

### 🍏 iOS (Sideloading)
YumeFlix is not on the App Store. You must **sideload** it using a computer.

**Requirements:**
- A Computer (Windows or macOS)
- [Impactor](https://impactor.khcrysalis.dev/) (Free and OpenSource) or [Sideloadly](https://sideloadly.io/) (Free)
- [iTunes](https://support.apple.com/en-us/106372) (if on Windows)

**Guide**
- [Impactor Guide](https://impactor.khcrysalis.dev/docs/getting-started/installing/)
- [Sideloadly Video Guide](https://www.youtube.com/watch?v=vqTsavQc3lQ)

**Steps:**
1. Download `skystream-ios-unsigned-v2.5.0.ipa` from the [Releases Page](https://github.com/akashdh11/skystream/releases/latest).
2. Open **Impactor** or **Sideloadly** on your computer.
3. Connect your iPhone/iPad via USB.
4. Drag the `.ipa` file into the Sideloadly window.
5. Enter your **Apple ID** in the configured field.
6. Click **Start**.
7. Once finished, the app will appear on your home screen.
8. On your device, go to **Settings > General > VPN & Device Management**, tap your email, and select **Trust**.
9. Set up Wi-Fi sync to automatically refresh your apps in the background

### 💻 Windows / macOS / Linux
1. Download the appropriate file for your OS (`skystream-windows.exe`, `skystream-macos.dmg`, `skystream-linux.deb`, etc.).
2. Install the app.
3. Run the application from your app launcher or terminal.
   - *macOS Note: If you see an “Unidentified Developer” warning, go to Settings → Privacy & Security and click Open Anyway to allow the app (one-time step).*
   - *Linux Note: You may need to install the following packages:*
     ```bash
     sudo apt-get update
     sudo apt-get install -y clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev libvlc-dev libasound2-dev
     ```

## 🛠️ Build from Source

To set up the development environment, clone the repository and run the setup commands. Detailed instructions for environment configuration, platform-specific builds, and project architecture can be found in our contributor guide:

👉 **[CONTRIBUTING.md](docs/CONTRIBUTING.md)**

### Quick Start
```bash
flutter pub get
flutter gen-l10n
dart run build_runner build --delete-conflicting-outputs
flutter run
```

For Android phone and TV APKs, use Flutter 3.47.5 or newer with a compatible Dart 3.13 SDK, JDK 17, Android API 37.0, Build Tools 37.0.0, and NDK 29.0.14206865. Build a single universal ARM APK (32-bit and 64-bit ARM) with:

```bash
flutter build apk --release --target-platform android-arm,android-arm64 \
  --obfuscate --split-debug-info=build/symbols \
  --build-name=2.3.3 --build-number=2303
```

**Signing and identity:** `applicationId` remains `yume.flix.by.nzr` to preserve app identity and sandbox data. Without your matching private release keystore in `android/key.properties`, the project produces a debug-signed APK for testing, not for public distribution. Android cannot install it over a copy signed with a different key; do not uninstall first unless you have backed up app data. Keep the `build/symbols` output private and backed up for release crash reports. Obfuscation/minification only raises the effort of casual inspection; it cannot make a distributed APK impossible to modify or reverse-engineer.

## 🤝 Contributing

We welcome contributions of all kinds! Whether you are fixing a bug, adding a feature, or helping with translations, your help is appreciated.

- **Found a bug?** Report it on our **[GitHub Issues](https://github.com/akashdh11/skystream/issues)** page.
- **Want to translate?** See our **[Translation Guide](docs/CONTRIBUTING_TRANSLATIONS.md)**.
- **Want to build a plugin?** Check the **[Extension Guide](https://github.com/akashdh11/skystream-tools/blob/main/DEVELOPER.md)**.
- **Need help?** Join the community on **[Discord](https://discord.gg/73XGA8Mxn9)** or **[Telegram](https://t.me/+Ez5Vsv2pUUFjZmNl)**.

---

## FAQ

<details>
<summary><b>How do I install extensions?</b></summary>
YumeFlix uses `.sky` or `.js` extension files. You can install them by navigating to <b>Settings > Extensions > Add Repository</b> and entering a repository URL (e.g., using a shortcode).
</details>

<details>
<summary><b>Where is the media stored?</b></summary>
YumeFlix is a streaming client and does not host any content. All media is streamed directly from the third-party extensions you install.
</details>


## Star History

## Star History

<a href="https://star-history.dera.page/#akashdh11/skystream&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=Date" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=akashdh11/skystream&type=Date" />
 </picture>
</a>


## Contributors

<a href="https://github.com/akashdh11/skystream/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=akashdh11/skystream" />
</a>

## License

[MIT](LICENSE)
