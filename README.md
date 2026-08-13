# arc

Private repository at [github.com/developconnected-dev/arc](https://github.com/developconnected-dev/arc).

This GitHub remote is ready to receive the project files you already have on your Mac. A cloud agent cannot read your local disk, so the upload has to be a `git push` from that machine.

## Push your local project

In Terminal on your Mac, go to the folder that contains your project (the one with your source files, not an empty clone of this repo):

```bash
cd /path/to/your/local/project
```

### If that folder is not a git repo yet

```bash
git init -b main
git remote add origin https://github.com/developconnected-dev/arc.git
git fetch origin
git add .
git commit -m "Add local project files"
git pull origin main --allow-unrelated-histories --no-rebase
git push -u origin main
```

### If that folder already has git history

```bash
git remote add origin https://github.com/developconnected-dev/arc.git
# If origin already exists, use: git remote set-url origin https://github.com/developconnected-dev/arc.git
git fetch origin
git pull origin main --allow-unrelated-histories --no-rebase
git push -u origin main
```

GitHub may ask you to sign in in the browser (HTTPS) or via SSH if you prefer `git@github.com:developconnected-dev/arc.git`.

After the push, this README can be replaced with a real project description.

## What this repo already includes

| File | Purpose |
| --- | --- |
| `.gitignore` | Keeps OS junk, secrets, and common build/dependency folders out of git |
| `.gitattributes` | Consistent line endings across macOS and Linux |
| `.github/pull_request_template.md` | Checklist for future pull requests |

Customize `.gitignore` for your language after the first push (Node, Python, Rust, etc.).
