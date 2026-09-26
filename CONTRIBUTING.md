# Contributing to OBP

Thank you for helping build credit for people banks leave out. Contributions of every kind are welcome: code, tests, translations, economic modelling, legal knowledge about your country, security review and documentation.

You can write in any language you are comfortable with in issues and discussions. Maintainers will reply in English and try to answer in your language too.

## Ways to help

| You are... | Start here |
|---|---|
| A native speaker of any language | [Translation](#translation) |
| A Solidity / Foundry developer | [good first issues](docs/good-first-issues.md), then `tests.json` items marked `not_started` |
| A TypeScript developer | `services/underwriter/` |
| An economist or data person | `sim/` and the parameters in [CLAUDE.md](CLAUDE.md) |
| Someone who knows how credit, stablecoins or courts work in your country | open a "Country insight" issue |
| A security reviewer | [SECURITY.md](SECURITY.md) |

## Setup

```
git clone https://github.com/Shilpan7298/Open-Bank.git && cd Open-Bank
./init.sh
```

`init.sh` installs Foundry if it is missing, then builds and runs every test suite: the contracts, the underwriter, the simulation and the translation check. It must pass before you open a pull request. You need git, Node 20+ and Python 3.11+. On Windows, use WSL.

## Workflow

1. Look for an existing issue, or open one to say what you plan to do. Small fixes can go straight to a pull request.
2. Fork the repo and create a branch: `feature/...`, `fix/...` or `i18n/<language>`.
3. Keep each pull request to one change. Write or update the tests first.
4. Run `./init.sh`. For contracts, also run `forge fmt` in `contracts/`.
5. Open the pull request and fill in the template. CI runs the same `init.sh`.

## Rules that keep the protocol safe

These rules exist because people's savings will depend on this code.

- **Tests are the specification.** Never delete or weaken a test to make it pass. If a test is wrong, explain why in the pull request and in `progress.md`, then fix it. Track new tests in `tests.json`.
- **Anything that moves funds needs fuzz or invariant tests.** Unit tests alone are not enough.
- **Respect upstream licences.** Only adapt code from repos marked "incorporate" in [docs/UPSTREAM.md](docs/UPSTREAM.md). Keep their SPDX and copyright headers, and add a row to [NOTICE.md](NOTICE.md). Never copy code from "reference only" repos, even small snippets.
- **The AI score is advice only.** No change may let a score approve or fund a loan by itself.
- **No secrets in the repo.** Use Anvil's public test keys in tests, and a gitignored `.env` for anything else.
- **No user-facing text in code.** Put it in `i18n/en.json` and reference it by key, so it can be translated.
- **Stay in scope.** Stick to the current phase in [docs/ROADMAP.md](docs/ROADMAP.md). Economic design changes (parameters, the loss order, who bears which loss) need an issue and the founder's agreement first.

By contributing, you agree that your contribution is licensed under AGPL-3.0-or-later.

## Translation

Every message a borrower, voucher or lender sees lives in [`i18n/`](i18n/README.md), with one JSON file per language. English (`en.json`) is the source.

- **Review a draft.** Files marked `"status": "needs_review"` were drafted by machine. Fix anything unnatural or wrong, then set the status to `"reviewed"`. Plain everyday words matter more than formal language: many readers are not finance experts.
- **Add a language.** Copy `en.json` to `<code>.json` (an ISO 639-1 code such as `ur`, `hi`, `sw`, `pt`, `fr`, `id`, `ha` or `am`). Translate the values, keep `{placeholders}` unchanged, and set `dir` to `rtl` for right-to-left scripts. Run `node i18n/check.mjs`.
- **Translate the README.** Copy an existing `README.<code>.md` and add a link to it at the top of every README.

### الترجمة

كل الرسائل التي يراها المستخدمون موجودة في مجلد `i18n/`. الملف `ar.json` ترجمة آلية أولية تحتاج إلى مراجعة من متحدث أصلي بالعربية. صحّح أي عبارة غير طبيعية، واستخدم كلمات بسيطة يفهمها الجميع، ثم غيّر الحالة إلى `reviewed`. يمكنك كتابة الملاحظات والأسئلة بالعربية.

### অনুবাদ

ব্যবহারকারীরা যত বার্তা দেখেন, সব `i18n/` ফোল্ডারে আছে। `bn.json` যন্ত্রে করা প্রাথমিক অনুবাদ, একজন বাংলাভাষীর যাচাই দরকার। অস্বাভাবিক বা ভুল বাক্য ঠিক করুন, সহজ দৈনন্দিন শব্দ ব্যবহার করুন, তারপর অবস্থা `reviewed` করে দিন। প্রশ্ন ও মন্তব্য বাংলায় লিখতে পারেন।

### Traducción

Todos los mensajes que ven los usuarios están en `i18n/`. El archivo `es.json` es un borrador automático que necesita revisión de un hablante nativo. Corrige lo que suene raro o esté mal, usa palabras simples y cotidianas y luego cambia el estado a `reviewed`. Puedes escribir tus comentarios y preguntas en español.

## Getting help

Open an issue with the question label, or comment on the issue you are working on. Be patient and kind: contributors live in many time zones and speak many languages. See the [Code of Conduct](CODE_OF_CONDUCT.md).
