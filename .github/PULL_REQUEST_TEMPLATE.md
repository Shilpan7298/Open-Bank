## What changes

<!-- One change per pull request. Link the issue: Closes #... -->

## Tests

- [ ] `./init.sh` passes locally
- [ ] New or changed behaviour has tests, and `tests.json` is updated
- [ ] Anything that moves funds has fuzz or invariant coverage
- [ ] No test was deleted or weakened (if a test was wrong, the reason is explained below and in `progress.md`)

## Checklist

- [ ] No user-facing text is hard-coded; new messages are in `i18n/en.json`
- [ ] Adapted upstream code keeps its headers and is listed in `NOTICE.md`
- [ ] No secrets or private keys
- [ ] Economic design changes (parameters, loss order) were agreed in an issue first
