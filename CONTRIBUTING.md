# Contributing

## Workflow

All changes must go through a pull request — direct pushes to `main` are blocked. Open a branch, push it, and open a PR.

## Commit messages

Commits follow [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/):

```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

Types used in this repo:

| Type | Use for |
|---|---|
| `feat` | A new feature or user-visible behavior change |
| `fix` | A bug fix |
| `docs` | Documentation only |
| `test` | Tests only |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `chore` | Maintenance, including releases (`chore(release): 0.4.0`) |

Mark breaking changes with `!` after the type and a `BREAKING CHANGE:` footer:

```
feat!: remove --no-confirm and -y

BREAKING CHANGE: --no-confirm and -y are removed.
```

PRs are squash-merged and the squash commit takes the **PR title** as its subject, so PR titles must follow the same format. Add user-visible changes to the `[Unreleased]` section of [CHANGELOG.md](CHANGELOG.md).

## Signed commits

Every commit must be GPG-signed. GitHub will reject unsigned commits at merge time.

If you haven't set this up:

```bash
git config --global commit.gpgsign true
git config --global user.signingkey <your-key-id>
```

See [GitHub's guide to signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits) for full setup instructions.

## Before opening a PR

Run the test suite:

```bash
brew install bats-core   # first time only
bats tests/command_generation.bats
```

If your change touches command construction in `mirra.sh`, update the corresponding `assert_arg` / `refute_arg` calls in `tests/command_generation.bats`.
