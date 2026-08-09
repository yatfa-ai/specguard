#!/usr/bin/env bash
set -e

# Ensure we're on the main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "Error: Not on main branch. Current branch: $CURRENT_BRANCH"
    exit 1
fi

# Check if working directory is clean
if [ -n "$(git status --porcelain)" ]; then
    echo "Error: Working directory has uncommitted changes"
    exit 1
fi

# Fail fast on migration problems that would abort the production deploy.
# A duplicate migration version number raises DuplicateMigrationVersionError
# during db:prepare on the server -> downtime. This DB-free check catches it
# before we bump the version and push to prod.
bash script/check_migrations.sh

# Read current version
if [ ! -f VERSION ]; then
    echo "Error: VERSION file not found"
    exit 1
fi

CURRENT_VERSION=$(cat VERSION)
echo "Current version: $CURRENT_VERSION"

# Bump patch version (0.1.0 -> 0.1.1)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
NEW_PATCH=$((PATCH + 1))
NEW_VERSION="$MAJOR.$MINOR.$NEW_PATCH"

echo "New version: $NEW_VERSION"

# Update VERSION file
echo "$NEW_VERSION" > VERSION

# Create commit
git add VERSION
git commit -m "bump: $CURRENT_VERSION -> $NEW_VERSION"

# Pull with rebase to incorporate any commits that landed on main since checkout
# Retry up to 3 times to handle concurrent pushes
MAX_RETRIES=3
RETRY_COUNT=0
PUSH_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if git pull --rebase origin main; then
        if git push origin main; then
            PUSH_SUCCESS=true
            break
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "Push failed, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    fi
done

if [ "$PUSH_SUCCESS" = false ]; then
    echo "Error: Failed to push version bump after $MAX_RETRIES attempts"
    exit 1
fi

# Push to prod branch (deploy mirror of main, fed only by this script).
# prod should always fast-forward from main; a non-fast-forward means a
# concurrent release run left an orphaned bump on prod (or prod otherwise
# diverged). main is the source of truth, so reconcile prod to main's tip.
# Each attempt tries a plain fast-forward push first, falling back to
# --force-with-lease only if prod diverged: the lease refuses to overwrite a
# prod tip that advanced since the fetch, preventing a true lost-update.
PROD_PUSH_SUCCESS=false
PROD_RETRIES=0
while [ $PROD_RETRIES -lt $MAX_RETRIES ]; do
    if git fetch origin prod 2>/dev/null; then
        EXPECTED_PROD=$(git rev-parse origin/prod)
        if git push origin main:prod || \
           git push --force-with-lease=prod:"$EXPECTED_PROD" origin main:prod; then
            PROD_PUSH_SUCCESS=true
            break
        fi
    else
        # prod does not exist yet (first release) — create it from main.
        if git push origin main:prod; then
            PROD_PUSH_SUCCESS=true
            break
        fi
    fi
    PROD_RETRIES=$((PROD_RETRIES + 1))
    if [ $PROD_RETRIES -lt $MAX_RETRIES ]; then
        echo "Prod push failed, retrying ($PROD_RETRIES/$MAX_RETRIES)..."
        sleep 5
    fi
done

if [ "$PROD_PUSH_SUCCESS" = false ]; then
    echo "Error: Failed to push to prod after $MAX_RETRIES attempts"
    exit 1
fi

echo "Version bumped to $NEW_VERSION and pushed to main and prod"
