# Translations

Every message a borrower, voucher, insurer or lender sees lives here, with one JSON file per language. Code refers to messages by key and never hard-codes user-facing text.

| File | Language | Status |
|---|---|---|
| `en.json` | English | source |
| `ar.json` | العربية (Arabic, right-to-left) | needs native review |
| `bn.json` | বাংলা (Bengali) | needs native review |
| `es.json` | Español (Spanish) | needs native review |

## Format

```json
{
  "_meta": { "language": "Español", "code": "es", "dir": "ltr", "status": "needs_review" },
  "messages": { "loan.state.repaid": "Pagado", "error.below_min_slice": "El monto mínimo para avalar es {min}." }
}
```

- **`status`:** `source` (English only), `needs_review` (a machine or first draft), or `reviewed` (checked by a native speaker).
- **`dir`:** `rtl` for Arabic, Urdu, Persian and Hebrew; `ltr` otherwise.
- **`{placeholders}`:** keep them exactly as they are. Numbers and dates are formatted per region by the app (for example `ar-EG` shows Arabic-Indic digits and `bn-BD` shows Bengali digits).
- **`loan.cancel_reason.*`:** one message per reason code the contracts emit. The checker fails if the contracts add a reason without a message.

## Writing well for our readers

Many readers are not finance experts and may be reading on a small phone.

- Use everyday words, short sentences, and the second person ("you").
- Say what happened and what the person can do next.
- Never blame, and never use jargon when a common word exists.

## Check

```
node i18n/check.mjs
```

It verifies that every language has the same keys and placeholders as English, that the metadata is valid, and that every contract cancel reason has a message. It runs in `./init.sh` and in CI.
