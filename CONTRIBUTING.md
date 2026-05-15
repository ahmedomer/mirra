# Contributing

## Workflow

All changes must go through a pull request — direct pushes to `main` are blocked. Open a branch, push it, and open a PR.

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
