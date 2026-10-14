# rescriva.com

The app's home page: one static HTML file with its images. No build step.

| Path | What it is |
| --- | --- |
| `index.html` | The page, with its CSS and the app's ink icons inline |
| `screens/` | Simulator screenshots, 660px wide (iPad 1032px), WebP |
| `assets/` | App icon, favicon (`icon.svg`, shared with share.rescriva.com) and the link preview image `og.png` |

## The App Store link

Until the app is live, every App Store button reads "Coming soon to the App Store" and goes nowhere.
When it's live, set `APP_STORE_URL` near the bottom of `index.html`:

```js
const APP_STORE_URL = "https://apps.apple.com/app/rescriva/id0000000000";
```

All three buttons (header, hero and the closing section) then link there and read "Download on the
App Store". To use Apple's official badge instead, download it from Apple's
[marketing tools](https://tools.applemarketingtools.com) and put it inside the `[data-store]` links.

For Safari's Smart App Banner, add this to the `<head>` with the real id:

```html
<meta name="apple-itunes-app" content="app-id=0000000000">
```

## Screenshots

Taken on the iPhone 17 Pro Max and iPad Pro 13-inch simulators with the sample library
(`-seedSampleLibrary YES`) and a 9:41 status bar:

```sh
xcrun simctl status_bar booted override --time 9:41 --batteryState discharging --batteryLevel 100 --wifiBars 3 --cellularBars 4
```

Save with `xcrun simctl io booted screenshot`, then resize to 660px wide WebP. Images ending in
`-dark` replace their light versions in dark mode. The hero animation needs `handwritten.webp` and
`document.webp` to be the same scan, Pages tab and Document tab.

## Previewing

```sh
python3 -m http.server 8790 --directory Website
```

Then open http://127.0.0.1:8790.
