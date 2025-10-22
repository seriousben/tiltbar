# Next Steps: Completing the Homebrew Release

This document outlines the remaining steps to complete the Homebrew release setup for TiltBar.

## What's Been Done

✅ **Codebase prepared:**
- Icons committed to repository (in `Sources/TiltBar/Resources/`)
- `.gitignore` updated to track icons
- `Makefile` updated (icon download now optional)
- `README.md` updated with Homebrew installation instructions

✅ **Release automation configured:**
- Release Please workflow (`.github/workflows/release-please.yml`)
- Release Please config (`.release-please-config.json`)
- Version manifest (`.release-please-manifest.json`)
- Builds universal binary (arm64 + x86_64)

✅ **Homebrew formula created:**
- Formula template in `Formula/tiltbar.rb`
- Ready to copy to tap repository

✅ **Documentation created:**
- `RELEASE.md` - Detailed release process guide
- Updated `README.md` - Contributing and installation sections

## What You Need to Do

### 1. Commit and Push the Changes

```bash
# Review the changes
git diff

# Stage the new files
git add .github/ .release-please-config.json .release-please-manifest.json
git add Formula/ RELEASE.md NEXT_STEPS.md
git add .gitignore Makefile README.md

# Commit using conventional commit format (important!)
git commit -m "feat: add homebrew distribution and release automation

- Configure Release Please for automated versioning
- Bundle Tilt icons in repository for distribution
- Add Homebrew formula template
- Update documentation with installation instructions
- Add release process documentation"

# Push to trigger Release Please
git push origin main
```

### 2. Wait for Release Please PR

After pushing, within a few minutes:
- Check: https://github.com/seriousben/tilt-status-bar/pulls
- You should see a new PR titled something like "chore(main): release 0.1.0"
- This PR will contain `CHANGELOG.md` and version updates

### 3. Review and Merge the Release PR

- Review the changes in the PR
- Merge the PR
- GitHub Actions will automatically:
  - Create tag `v0.1.0`
  - Create GitHub release
  - Build universal binary
  - Upload tarball to release

### 4. Publish the Homebrew Tap Repository

The tap repository has been prepared in `../homebrew-tiltbar/`. Once the release is created:

```bash
# Navigate to the tap repository
cd ../homebrew-tiltbar

# Get the SHA256 of the release tarball
# (Replace v0.1.0 with your actual version if different)
curl -sL https://github.com/seriousben/tilt-status-bar/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256

# Edit Formula/tiltbar.rb:
# - Replace REPLACE_WITH_ACTUAL_SHA256 with the SHA from above
# - Verify the version in the URL matches your release

# Create the repository on GitHub:
# (Go to https://github.com/new)
# Name: homebrew-tiltbar
# Description: Homebrew tap for TiltBar
# Public repository

# Commit and push
git commit -m "feat: initial formula for tiltbar v0.1.0"
git remote add origin https://github.com/seriousben/homebrew-tiltbar.git
git push -u origin main
```

### 5. Test the Installation

```bash
# Install from your tap
brew install seriousben/tiltbar/tiltbar

# Start Tilt in a test project
cd /path/to/your/tilt/project
tilt up

# Run TiltBar
tiltbar

# Verify:
# - TiltBar icon appears in menu bar
# - Shows correct status from Tilt
# - Can open Tilt in browser from menu
```

### 6. Update Project Status (Optional)

Consider adding a badge to README.md:

```markdown
[![Homebrew](https://img.shields.io/badge/homebrew-seriousben%2Ftiltbar-blue)](https://github.com/seriousben/homebrew-tiltbar)
```

## Future Releases

Once everything is set up, future releases are simple:

1. Make commits with conventional commit messages:
   ```bash
   git commit -m "feat: add new feature"
   git commit -m "fix: resolve issue"
   ```

2. Push to main - Release Please accumulates changes

3. Merge the Release PR when ready

4. Update Homebrew formula with new version:
   ```bash
   cd ../homebrew-tiltbar
   # Get new SHA256
   curl -sL https://github.com/seriousben/tilt-status-bar/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256
   # Update Formula/tiltbar.rb
   git add Formula/tiltbar.rb
   git commit -m "feat: update tiltbar to vX.Y.Z"
   git push
   ```

## Troubleshooting

If something goes wrong, check `RELEASE.md` for detailed troubleshooting steps.

## Questions?

- Release Please docs: https://github.com/googleapis/release-please
- Homebrew formula docs: https://docs.brew.sh/Formula-Cookbook
- Conventional Commits: https://www.conventionalcommits.org/

---

**Ready to start?** Begin with step 1 above! 🚀
