# Security

OBP is in **Phase 1: testnet only, no real funds**. Even so, the contracts are designed to hold people's savings one day, so we treat security reports seriously from the start.

## Reporting a vulnerability

Please do **not** open a public issue for a vulnerability. Use GitHub's private reporting instead: **Security → Report a vulnerability** on this repository. If that is unavailable, contact [@Shilpan7298](https://github.com/Shilpan7298) and ask for a private channel.

Please include:

- the affected file and function
- a concrete exploit scenario
- if possible, a failing Foundry test that proves it (see `contracts/test/`)

## Most wanted

Findings in these areas are the most valuable:

- **Loss waterfall ordering:** a lower layer paying while a higher one still has capacity for that loan.
- **Accounting:** conservation, rounding, and share inflation on the ERC-4626 vaults.
- **Withdrawals before losses:** voucher or insurer capital escaping ahead of a loss.
- **Score abuse:** replaying a score, or bypassing the scorer quorum.
- **Access control:** anything the guardian can do beyond pausing.
- **Sanctions:** any route that pays out to a sanctioned address.
- **Prompt injection:** a borrower proposal that moves the AI score.

There is no bug bounty yet. Credited reporters will be listed in release notes.
