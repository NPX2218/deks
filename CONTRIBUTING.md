# Contributing to Deks

Thanks for your interest in contributing to Deks! Here's how to get started.

## Getting started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/NPX2218/deks.git`
3. Create a branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test thoroughly on macOS 13+ (both Apple Silicon and Intel if possible)
6. Commit with a clear message: `git commit -m "Add: workspace snapshot export"`
7. Push: `git push origin feature/your-feature-name`
8. Open a Pull Request

## Development setup

You'll need Xcode 15.0+ and macOS 13.0 (Ventura) or later.

```bash
brew bundle          # Install dependencies
xcodegen generate    # Generate Xcode project
open Deks.xcodeproj  # Open in Xcode
```

Grant Accessibility permission to the debug build when prompted.

## Commit messages

Use clear, descriptive commit messages with a prefix:

| Prefix | Usage |
|--------|-------|
| `Add:` | New feature |
| `Fix:` | Bug fix |
| `Refactor:` | Code restructure without behavior change |
| `Docs:` | Documentation only |
| `Style:` | Formatting, no code change |
| `Test:` | Adding or updating tests |
| `Chore:` | Build scripts, CI, dependencies |

## Code style

- Follow Swift standard conventions
- Use `// MARK:` sections to organize files
- Keep functions focused and under ~40 lines where possible
- Add doc comments to public APIs
- No force unwraps (`!`) outside of tests

## Pull requests

- One feature or fix per PR
- Include a clear description of what changed and why
- Add screenshots or screen recordings for UI changes
- Make sure the project builds with no warnings
- Reference related issues with `Fixes #123` or `Closes #123`

## Reporting bugs

Use the [Bug Report](https://github.com/NPX2218/deks/issues/new?template=bug_report.yml) issue template. Include:

- macOS version
- Deks version
- Steps to reproduce
- Expected vs actual behavior
- Screenshots if applicable

## Suggesting features

Use the [Feature Request](https://github.com/NPX2218/deks/issues/new?template=feature_request.yml) issue template. Describe:

- The problem you're trying to solve
- Your proposed solution
- Any alternatives you've considered

## Code of conduct

Be kind, be constructive, be respectful. We're all here to build something great.

---

Questions? Open a [Discussion](https://github.com/NPX2218/deks/discussions) or reach out.
