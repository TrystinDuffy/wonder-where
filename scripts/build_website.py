#!/usr/bin/env python3
"""Build the public website from the app's shared copy; no dependencies required."""
from html import escape
from pathlib import Path
import re
import shutil
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parent.parent
OUTPUT = ROOT / "build" / "website"
SITE_URL = "https://trystinduffy.github.io/wonder-where/"
BASE = urlsplit(SITE_URL).path


def inline(text):
    """Render the links and emphasis used by the public Markdown documents."""
    pattern = r"\[([^\]]+)\]\((https://[^\s)]+|mailto:[^\s)]+)\)|\*\*([^*]+)\*\*"
    parts, end = [], 0
    for match in re.finditer(pattern, text):
        parts.append(escape(text[end:match.start()]))
        if match.group(1):
            parts.append(f'<a href="{escape(match.group(2), quote=True)}">{escape(match.group(1))}</a>')
        else:
            parts.append(f"<strong>{escape(match.group(3))}</strong>")
        end = match.end()
    parts.append(escape(text[end:]))
    return "".join(parts)


def document(filename, title):
    source = (ROOT / "AppStore" / filename).read_text(encoding="utf-8")
    rendered, contents = [], []
    for block in source.strip().split("\n\n"):
        if block.startswith("# "):
            rendered.append(f"<h1>{escape(title)}</h1>")
        elif block.startswith("## "):
            heading = block[3:].strip()
            anchor = re.sub(r"[^a-z0-9]+", "-", heading.lower()).strip("-")
            rendered.append(f'<h2 id="{anchor}">{escape(heading)}</h2>')
            contents.append(f'<li><a href="#{anchor}">{escape(heading)}</a></li>')
        else:
            if re.match(r"^(?:#{3,}|[-*] |\d+\. |```)", block):
                raise ValueError(f"Unsupported Markdown in {filename}: {block[:40]}")
            rendered.append(f"<p>{inline(block.replace(chr(10), ' '))}</p>")
    # Keep the introduction first and make long documents easy to navigate.
    first_section = next(i for i, part in enumerate(rendered) if part.startswith("<h2"))
    rendered.insert(first_section, '<details><summary>On this page</summary><ul>' + "".join(contents) + '</ul></details>')
    return '<article class="document">' + "\n".join(rendered) + '</article>'


def page(path, title, description, content, current=None):
    def navigation():
        return "".join(
            f'<a href="{BASE}{slug}"' + (' aria-current="page"' if current == key else '') + f'>{label}</a>'
            for key, slug, label in [("support", "support/", "Support"), ("privacy", "privacy/", "Privacy")]
        )

    html = f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="description" content="{escape(description, quote=True)}">
  <meta name="theme-color" content="#fcfaf6">
  <title>{escape(title)}</title>
  <link rel="canonical" href="{SITE_URL}{path if path != '404.html' else ''}">
  <link rel="icon" type="image/png" href="{BASE}assets/app-icon.png">
  <link rel="apple-touch-icon" href="{BASE}assets/app-icon.png">
  <link rel="stylesheet" href="{BASE}assets/styles.css">
</head>
<body>
  <a class="skip" href="#main">Skip to content</a>
  <header class="site-header shell">
    <a class="brand" href="{BASE}"><img src="{BASE}assets/app-icon.png" width="38" height="38" alt="">WonderWhere</a>
    <nav aria-label="Main navigation">{navigation()}</nav>
  </header>
  <main id="main" class="shell">{content}</main>
  <footer class="site-footer shell">
    <p>© 2026 Trystin Duffy</p>
    <nav aria-label="Footer">{navigation()}<a href="mailto:trystinduffy@gmail.com">Contact</a></nav>
  </footer>
</body>
</html>
'''
    target = OUTPUT / (path if path.endswith(".html") else path + "index.html")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(html, encoding="utf-8")


def main():
    # This directory contains only generated public files, never app data or notes.
    if OUTPUT.exists():
        shutil.rmtree(OUTPUT)
    assets = OUTPUT / "assets"
    assets.mkdir(parents=True)
    shutil.copyfile(ROOT / "website" / "styles.css", assets / "styles.css")
    shutil.copyfile(ROOT / "CompassDay/Assets.xcassets/AppIcon.appiconset/AppIcon.png", assets / "app-icon.png")
    home = (ROOT / "website" / "home.html").read_text(encoding="utf-8").replace("{{base}}", BASE)
    page("", "WonderWhere — A compass for surprise outings", "Plan the day. Keep the destination a surprise. An iPhone compass app for meaningful outings, made by Trystin Duffy.", home)
    page("privacy/", "Privacy Policy — WonderWhere", "WonderWhere’s privacy policy: local trip storage, location, Apple Maps, optional calendar sharing, notifications, and your choices.", document("privacy-policy.md", "Privacy policy"), "privacy")
    page("support/", "Help & Support — WonderWhere", "Help with WonderWhere, from your first outing to compass guidance, scheduling, and calendar sharing. Contact Trystin Duffy for support.", document("support.md", "Help & support"), "support")
    page("404.html", "Page not found — WonderWhere", "Find your way back to WonderWhere.", f'<section class="document"><h1>A little off course.</h1><p>This page could not be found.</p><a class="button" href="{BASE}">Back to WonderWhere</a></section>')
    (OUTPUT / ".nojekyll").touch()
    print(f"Built four public pages in {OUTPUT.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
