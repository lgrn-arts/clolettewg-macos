#!/bin/sh
# publish-to-github.sh — create the GitHub repo and push this tree to it.
#
#   ./publish-to-github.sh <your-github-username>
#
# e.g. ./publish-to-github.sh octocat
#      -> https://github.com/octocat/amneziawg-mavericks
#
# Uses gh if it's installed and authenticated, otherwise it wires up the
# remote and asks you to create the empty repo first. Safe to re-run.

set -e

REPO_NAME="amneziawg-mavericks"
VISIBILITY="public"     # set to "private" if you'd rather

USERNAME="${1:-}"
if [ -z "$USERNAME" ]; then
    echo "usage: $0 <github-username>" >&2
    exit 1
fi

cd "$(dirname "$0")"

if [ ! -d .git ]; then
    echo "error: not a git repository — run this from the project root." >&2
    exit 1
fi

# Don't publish a dirty tree, so what lands matches what you tested.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: uncommitted changes present. Commit or stash first:" >&2
    git status --short >&2
    exit 1
fi

echo "== pre-publish checks =="

# A WireGuard private key leaked into a public repo can't be recalled.
if git ls-files | grep -qiE '\.(key|pem|p12)$|credential'; then
    echo "error: possible credential file is tracked. Remove it first." >&2
    exit 1
fi
echo "   no tracked credential files"

# Without the prebuilt daemon a fresh clone can't `make`.
if ! git ls-files --error-unmatch bin/awgd.darwin-amd64 >/dev/null 2>&1; then
    echo "error: bin/awgd.darwin-amd64 is not tracked." >&2
    echo "       Without it a fresh clone cannot build. Run:" >&2
    echo "         git add -f bin/awgd.darwin-amd64 && git commit -m 'add prebuilt daemon'" >&2
    exit 1
fi
echo "   prebuilt daemon is tracked"

COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
echo "   $COMMITS commit(s) on $(git branch --show-current)"

# Commits keep whatever author they were made with, and GitHub links a commit
# to your account by matching the email. A placeholder address means the
# commits show up under a grey name nobody can click.
AUTHOR_EMAIL=$(git log -1 --format='%ae')
AUTHOR_NAME=$(git log -1 --format='%an')
case "$AUTHOR_EMAIL" in
    *localhost|*local|*@nanami*|"")
        echo
        echo "   WARNING: commits are authored as \"$AUTHOR_NAME <$AUTHOR_EMAIL>\"."
        echo "   GitHub matches commits to accounts by email, so these won't be"
        echo "   linked to you. To fix before pushing:"
        echo
        echo "     git filter-branch --env-filter '"
        echo "       export GIT_AUTHOR_NAME=\"Your Name\""
        echo "       export GIT_AUTHOR_EMAIL=\"you@example.com\""
        echo "       export GIT_COMMITTER_NAME=\"Your Name\""
        echo "       export GIT_COMMITTER_EMAIL=\"you@example.com\"' -- --all"
        echo
        printf '   Continue anyway? [y/N] '
        read -r ans || true
        case "$ans" in y|Y) ;; *) echo "   aborted."; exit 1 ;; esac
        ;;
esac

# ------------------------------------------------------------------ push ---
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    echo
    echo "== creating repo with gh =="
    gh repo create "$REPO_NAME" \
        "--$VISIBILITY" \
        --source=. \
        --remote=origin \
        --push \
        --description "Native GUI AmneziaWG (obfuscated WireGuard) client for OS X 10.9 Mavericks"
else
    echo
    echo "gh not available or not authenticated — falling back to plain git."
    echo
    echo "  1. Create an EMPTY repo on github.com named '$REPO_NAME' ($VISIBILITY)."
    echo "     Do NOT tick 'Add a README' or '.gitignore' — this project has both."
    echo
    printf '  2. Press return once it exists, or Ctrl-C to abort: '
    read -r _ || true

    git remote remove origin 2>/dev/null || true
    git remote add origin "git@github.com:$USERNAME/$REPO_NAME.git"

    echo
    echo "== pushing =="
    git push -u origin "$(git branch --show-current)"
fi

echo
echo "== done =="
echo "   https://github.com/$USERNAME/$REPO_NAME"
echo
echo "   Suggested next steps:"
echo "     • Settings → Pages is not needed; the README renders on the repo page."
echo "     • Create a release:  git tag -a v1.4 -m 'v1.4' && git push --tags"
echo "       then attach the prebuilt daemon + Nanami-<ver>.pkg as assets."
