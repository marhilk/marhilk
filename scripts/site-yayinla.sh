#!/bin/sh
# yayin/site/ içeriğini marhilk.github.io deposuna gönderir (site birkaç dakikada güncellenir).
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q git@github.com:marhilk/marhilk.github.io.git "$work"
find "$work" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
cp -R yayin/site/. "$work/"
touch "$work/.nojekyll"
cd "$work"
git add -A
if git diff --cached --quiet; then echo "değişiklik yok"; exit 0; fi
git -c user.name="Marhilk" -c user.email="marhilk@users.noreply.github.com" commit -q -m "Site güncellendi"
git push -q origin main
echo "gönderildi"
