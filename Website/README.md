# rescriva.com

The app's website: static HTML with its images, published to rescriva.com by GitHub Pages. No build
step. Nothing loads from other sites: no analytics, no cookies, and the fonts are served from here.

| Path | What it is |
| --- | --- |
| `index.html` | The home page, with the app's ink icons inline |
| `privacy/index.html` | The privacy policy. Its URL, https://rescriva.com/privacy/, is the Privacy Policy URL in App Store Connect |
| `support/index.html` | Help and contact. https://rescriva.com/support/ is the Support URL in App Store Connect |
| `404.html` | The page for addresses that don't exist. GitHub Pages serves it at any path, so its links start with `/` |
| `style.css` | The stylesheet for every page |
| `fonts/` | DM Sans and Newsreader (Latin, variable), under the SIL Open Font License in `fonts/OFL.txt` |
| `screens/` | Simulator screenshots, 660px wide (iPad 1032px), WebP |
| `assets/` | App icon, favicon (`icon.svg`, shared with share.rescriva.com) and the link preview image `og.png` |

## Before the first deploy

The privacy and support pages give **support@rescriva.com** as the contact address. That mailbox
doesn't exist yet. Either set up forwarding for it (Squarespace → Domains → rescriva.com → Email
forwarding), or replace it with a real address. It's in `privacy/index.html` (twice) and
`support/index.html` (once).

The privacy policy says the Share Nearby relay uses what it receives only to introduce two devices
and keeps nothing after they disconnect. Check that still matches the Worker in
[bowman-mw/rescriva-share](https://github.com/bowman-mw/rescriva-share). When the app changes what
it stores, syncs or sends, update `privacy/index.html` and its date, and the in-app Privacy text in
`scanner/Views/SettingsView.swift`.

## Deploying

`.github/workflows/pages.yml` publishes this folder, and only this folder, whenever a push to `main`
changes something in it. It can also be run by hand from the Actions tab.

One-time setup, in the repository on GitHub:

1. Settings → Pages → Build and deployment → Source: **GitHub Actions**.
2. Custom domain: **rescriva.com**. Once the DNS check passes, tick **Enforce HTTPS**.

rescriva.com's DNS is at Squarespace. The apex domain needs four `A` records pointing at GitHub
Pages (185.199.108.153, 185.199.109.153, 185.199.110.153, 185.199.111.153), and `www` a `CNAME`
to `bowman-mw.github.io`.

GitHub Pages can't set response headers, so there's no `_headers` file here.

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

Then open http://127.0.0.1:8790. The Python server doesn't serve `404.html` for missing pages, so
open http://127.0.0.1:8790/404.html to see it.
