# Good first issues

Each task below is self-contained. It names the files involved and says what done looks like. Comment on the matching GitHub issue (or open one) before starting, so two people don't take the same task. Tasks marked 🌍 need no programming.

## Translation 🌍

1. **Review the Arabic draft.** Native Arabic speakers, ideally one from Egypt: `i18n/ar.json` and `README.ar.md`. Done when every message reads naturally in plain words and `status` is `reviewed`.
2. **Review the Bengali draft.** Native Bengali speakers, ideally from Bangladesh: `i18n/bn.json` and `README.bn.md`.
3. **Review the Spanish draft.** Native Spanish speakers, ideally from Argentina: `i18n/es.json` and `README.es.md`. Use voseo where Argentine readers expect it, or propose an `es-AR` variant.
4. **Add a new language.** Urdu, Hindi, Swahili, Portuguese, French, Indonesian, Tagalog, Hausa, Yoruba, Amharic, Turkish, Persian or Vietnamese. Copy `i18n/en.json`, translate it, and run `node i18n/check.mjs`.
5. **Local financial terms glossary.** Add `i18n/GLOSSARY.md`: how "collateral", "voucher", "installment" and "default" are said in everyday speech in your country, so translations use familiar words.

## Country knowledge 🌍

6. **Country insight reports.** Use the "Country insight" issue template for Egypt, Bangladesh, Argentina, Nigeria, Pakistan, Kenya, Lebanon, Venezuela or Turkey. It feeds the jurisdiction tiers and the simulation's country-shock scenarios.

## Smart contracts (Solidity, Foundry)

7. **Custom-error selectors in `i18n`.** Map every custom error a user can hit (e.g. `ExceedsCreditLimit`, `BelowMinSlice`, `BidTooSmall`) to an `error.*` key, and add a check in `i18n/check.mjs` that every such error has a message.
8. **Gas snapshot.** Add `forge snapshot` for the happy-path lifecycle test and a CI step that reports gas changes. Low gas matters for small loans.
9. **More edge-case tests.** Pick any `test/unit/*.t.sol` and add boundary tests (zero amounts, maximum values, exact deadlines). Track them in `tests.json`.
10. **NatSpec review.** Read one module in `contracts/src/` and make its comments clear to a newcomer.

## Underwriter (TypeScript)

11. **Local-currency income field.** Add an optional `income` attestation (amount and currency) to `VerifiedData`. Show it in the prompt, and have the mock scorer weigh currency risk when the income currency is not USD.
12. **Proposal length and script checks.** Reject empty or oversized proposals with a clear error. Add tests with mixed right-to-left and left-to-right text.

## Simulation (Python)

13. **Currency devaluation shock.** In `sim/`, model a borrower cohort whose local currency loses 30-60% in a year, and measure defaults per waterfall layer. See "country shock" in progress.md.

## Bigger tasks for experienced contributors

These are listed in [ROADMAP.md](ROADMAP.md): basket capital earning yield (IB-13), freezing withdrawals while a loan is late, recovery after default, and the security review.
