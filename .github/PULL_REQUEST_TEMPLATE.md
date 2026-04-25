## Description

<!-- What does this PR do? Link any related issues. -->

## Type of Change

- [ ] 🐛 Bug fix (non-breaking change that fixes an issue)
- [ ] ✨ New feature (non-breaking change that adds functionality)
- [ ] 🐒 New monkey (adds a new specialized agent)
- [ ] 📝 Documentation update
- [ ] ♻️ Refactor (no functional changes)
- [ ] 🔧 Infrastructure (shared modules, git providers, scoring)

## Monkey Affected

<!-- Which monkey(s) does this change touch? -->

- [ ] Run-Player (orchestrator)
- [ ] Run-PlayerList (multi-repo)
- [ ] Rafiki / Abu / Diddy Kong / King Louie
- [ ] Mojo Jojo / Donkey Kong / Marcel
- [ ] Curious George / Playbook Runner
- [ ] Shared modules (MonkeyCommon, GitProviders, DocHealthScorer)
- [ ] Prompts

## Testing

<!-- How did you test this? -->

- [ ] Ran affected monkey standalone against a real repo
- [ ] Ran via orchestrator (`Run-Player.ps1`) end-to-end
- [ ] Tested with `-CommitMode dry-run` first
- [ ] Verified no repo-specific references leaked into code

## Checklist

- [ ] My code follows the [contributing guidelines](CONTRIBUTING.md)
- [ ] I've tested on at least one real repo
- [ ] I've updated README.md if adding new features/monkeys/packs
- [ ] No hardcoded repo paths, emails, or org-specific references
- [ ] New monkey follows the standardized contract (if applicable)
