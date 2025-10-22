# Release Process

This document explains how TiltBar uses Release Please for automated releases and Homebrew distribution.

## How It Works

### Automated Releases with Release Please

1. **Make commits using Conventional Commits format:**
   ```bash
   git commit -m "feat: add new feature"
   git commit -m "fix: resolve bug"
   git commit -m "docs: update documentation"
   ```

2. **Push to main:**
   - Release Please bot creates/updates a "Release PR"
   - The PR includes version bump and CHANGELOG updates
   - Multiple commits accumulate in one release

3. **Merge the Release PR:**
   - Release Please creates a GitHub release
   - Workflow builds universal binary (arm64 + x86_64)
   - Uploads tarball to the release

### Commit Types

- `feat:` - New feature → minor version bump (0.1.0 → 0.2.0)
- `fix:` - Bug fix → patch version bump (0.1.0 → 0.1.1)
- `feat!:` or `BREAKING CHANGE:` - Breaking change → major version bump (0.1.0 → 1.0.0)
- `docs:`, `chore:`, `ci:`, etc. - No version bump, but included in CHANGELOG

## First Release Setup

### Step 1: Commit and Push Initial Setup

```bash
# Stage all the release automation files
git add .github/ .release-please-config.json .release-please-manifest.json
git add .gitignore Makefile README.md RELEASE.md Formula/
git add Sources/TiltBar/Resources/*.png Sources/TiltBar/Resources/*.ico

# Create initial commit using conventional commit format
git commit -m "feat: initial release with Homebrew support

- Add Release Please automation
- Bundle Tilt icons in repository
- Add Homebrew formula template
- Update installation instructions"

# Push to main
git push origin main
```

### Step 2: Wait for Release Please

After pushing, Release Please will:
1. Create a PR titled "chore(main): release 0.1.0" (or similar)
2. The PR will include CHANGELOG.md and version updates

### Step 3: Merge the Release PR

1. Review the Release PR
2. Merge it
3. Release Please will:
   - Create tag `v0.1.0`
   - Create GitHub release
   - Build workflow runs and uploads tarball

### Step 4: Publish Homebrew Tap Repository

The tap repository has been prepared at `../homebrew-tiltbar/`.

```bash
# Navigate to the tap repository
cd ../homebrew-tiltbar

# Get the SHA256 of the release tarball
curl -sL https://github.com/seriousben/tilt-status-bar/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256

# Edit Formula/tiltbar.rb and replace:
# - REPLACE_WITH_ACTUAL_SHA256 with the actual SHA256
# - Verify the version in the URL matches your release

# Create the repository on GitHub: homebrew-tiltbar
# Then push
git add Formula/tiltbar.rb
git commit -m "feat: initial formula for tiltbar v0.1.0"
git remote add origin https://github.com/seriousben/homebrew-tiltbar.git
git push -u origin main
```

### Step 5: Test Installation

```bash
# Test the formula
brew install seriousben/tiltbar/tiltbar

# Run the app
tiltbar

# Verify it appears in your menu bar
```

## Subsequent Releases

Once set up, releasing new versions is fully automated:

1. Make commits with conventional commit messages
2. Release Please accumulates changes in a release PR
3. Merge the release PR
4. GitHub Actions automatically:
   - Builds and uploads release artifacts
   - Updates the Homebrew formula with new version and SHA256
   - Commits and pushes to homebrew-tiltbar repository

No manual intervention needed!

## Troubleshooting

### Release Please not creating PR

- Ensure commits use conventional commit format
- Check `.release-please-config.json` is valid JSON
- Look at GitHub Actions logs for errors

### GitHub Actions failing

- Check that Swift version in workflow matches Package.swift
- Verify paths in workflow are correct
- Ensure icons exist in Sources/TiltBar/Resources/

### Tap update failing

- Verify `TAP_GITHUB_TOKEN` secret is set correctly
- Ensure the token has `repo` scope
- Check GitHub Actions logs in the release workflow
- Verify homebrew-tiltbar repository exists and is accessible

### Homebrew install failing

- Test formula locally: `brew install --build-from-source ./Formula/tiltbar.rb`
- Verify SHA256 matches the tarball
- Check that release tarball was uploaded correctly
- Ensure Xcode Command Line Tools are installed: `xcode-select --install`

## Manual Release (if needed)

If you need to create a release manually:

```bash
# Tag the release
git tag -a v0.1.0 -m "Release v0.1.0"
git push origin v0.1.0

# GitHub Actions will build and upload artifacts automatically
```
