# Contributing to Playbook 🐒

Thanks for your interest in contributing! This project thrives on community input — whether it's a new monkey, a bug fix, or a better prompt.

## How to Contribute

### 🐛 Report a Bug

1. Open an [Issue](../../issues/new?template=bug_report.md)
2. Include: which monkey, the error output, repo language/size
3. Attach the `.monkey-output/` report if possible

### 💡 Request a Feature

1. Open an [Issue](../../issues/new?template=feature_request.md)
2. Describe the use case — what problem does it solve?
3. If proposing a new monkey, include: what it discovers, how it generates questions

### 🔧 Submit a Pull Request

1. **Fork** the repo and create a branch from `master`
2. **Make your changes** — follow the conventions below
3. **Test locally** — run your change against a real repo
4. **Open a PR** — fill out the template, link any related issues

### 🐒 Add a New Monkey

Want to add monkey #10? Here's the contract:

1. Create `monkey-army/your-monkey.ps1`
2. Follow the **standardized monkey contract** (see [README](README.md#standardized-monkey-contract))
3. Support both standalone and `-Internal` (orchestrated) modes
4. Import `shared/MonkeyCommon.psm1` for retry, model, reporting
5. Return the standard result object (MonkeyName, ExitStatus, QuestionsAsked, etc.)
6. Add your monkey to the pack definitions in `Run-Player.ps1`
7. Update README.md roster table

## Conventions

### PowerShell Style

- Use `[CmdletBinding()]` and named parameters
- Use `$ErrorActionPreference = "Stop"` at script top
- Wrap JSON parsing with `@()` (PowerShell unwraps single-element arrays)
- Use `Write-Host` with `-ForegroundColor` for user-facing output
- Use `Write-Verbose` for debug output (enabled with `-ShowVerbose`)

### File Structure

```
monkey-army/
├── your-monkey.ps1         ← Main script (standalone + internal modes)
shared/
├── MonkeyCommon.psm1       ← Add shared functions here, not in individual monkeys
```

### Commit Messages

```
feat: Add new monkey — YourMonkey (brief description)
fix: Fix JSON parsing in Abu when single gap found
docs: Update README with new pack definitions
```

### Testing Your Changes

```powershell
# Test individual monkey
.\monkey-army\your-monkey.ps1 -RepoPath "C:\test-repo" -DryRun

# Test via orchestrator
.\Run-Player.ps1 -RepoPath "C:\test-repo" -Monkeys your-monkey -CommitMode dry-run -ShowVerbose
```

## Code of Conduct

Be respectful, constructive, and inclusive. We're building tools that help developers — let's treat each other the way we'd want to be treated. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Questions?

Open a [Discussion](../../discussions) — no question is too small.
