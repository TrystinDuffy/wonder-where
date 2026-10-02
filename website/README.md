# WonderWhere website

Public pages:

- Overview / App Store marketing URL: https://trystinduffy.github.io/wonder-where/
- Privacy policy: https://trystinduffy.github.io/wonder-where/privacy/
- Help and support: https://trystinduffy.github.io/wonder-where/support/

The site is static HTML and CSS, hosted on GitHub Pages. It has no JavaScript, analytics, third-party fonts, or form backend. Contact links open an email to the public support address.

## Update the pages

Edit `AppStore/privacy-policy.md` or `AppStore/support.md` to update both the website and the documents bundled into the next app build. Edit `website/home.html` for the overview and `website/styles.css` for appearance. The website copies the app's current icon at build time.

Pushing those changes to `main` automatically builds and publishes the site using `.github/workflows/pages.yml`. Only generated public pages, the stylesheet, and the icon are included in the Pages artifact. Internal App Store notes, app source, and documentation screenshots are not website content.

The repository's **Settings → Pages → Build and deployment → Source** must be **GitHub Actions**. The workflow can also be run manually from Actions.

## Local preview

Run `python3 scripts/build_website.py`. Generated files go in the ignored `build/website` directory. To preview the same project path used on GitHub Pages:

```sh
mkdir -p build/preview
ln -sfn ../website build/preview/wonder-where
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/preview
```

Open http://127.0.0.1:8080/wonder-where/ in a browser. No packages or API keys are needed. If the repository or hosting URL changes, update `SITE_URL` in the builder and the URLs in App Store metadata.
