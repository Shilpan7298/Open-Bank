# Using OBP loans in the real economy

OBP is built on crypto lending: stablecoins, on-chain collateral, auctions and vaults. But its borrowers need money for real life, like stock for a shop, seeds before planting, school fees or a hospital bill. They are paid in Egyptian pounds, taka or pesos, not in dollars on a blockchain. This page describes that journey and what the protocol does, and does not yet do, at each step.

## The money journey

```
 local income ──cash-in──▶ stablecoin ──repay──▶ OBP ──disburse──▶ stablecoin ──cash-out──▶ local cash / supplier
  (wages, sales)   (exchange, P2P,                              (drawdownTo a partner)   (mobile money, bank,
                    mobile money agent)                                                     shop, school)
```

| Step | In the protocol today | Real-world partner (later phases) |
|---|---|---|
| Receive the loan | `drawdown` pays the borrower's wallet. `drawdownTo` pays a chosen address, such as an off-ramp partner, a supplier or a school. That address is sanctions-screened, and the debt stays with the borrower. | Licensed exchanges, mobile-money operators (bKash, Vodafone Cash, Mercado Pago and similar), P2P desks |
| Spend it | Off-chain | Local cash or a direct payment to the supplier |
| Repay | `repay` accepts payment from **anyone**. An employer, a relative sending remittances, or a cash-in agent can pay on the borrower's behalf, and the borrower's credit record still improves. | Cash-in agents and remittance corridors |
| Explain it | `i18n/` covers every state, reason, purpose and warning, in the borrower's language | App (Phase 2) |

## Real risks for real borrowers

- **Currency risk.** The loan is in dollars. If the local currency falls 30%, every installment costs 30% more in local money. This is the biggest default driver in these economies, so it gets its own message (`concept.currency_risk`). The underwriter weighs it, and `sim/` models it as a country shock. Showing installments in local currency is a Phase 2 app feature. Local-currency stablecoins could remove the mismatch later, if trustworthy ones exist.
- **Cash-in and cash-out costs.** Spreads and fees can add several percentage points to the real cost of borrowing. The target all-in APR in CLAUDE.md (9% to 13%) should be measured including them.
- **Timing.** Salaries are monthly, harvests are seasonal, and small-shop income is daily. Today's schedule is equal installments; see the open questions below.
- **Legality.** Using stablecoins is widespread in Argentina, restricted in Egypt, and discouraged by Bangladesh's central bank. Per-country legal review, and licensed partners for cash-in and cash-out, come before any real funds.
- **Fraud and coercion.** Loan-sharking pressure, fake vouchers, and scams that pose as the protocol. On-chain staking of voucher money makes fake vouching expensive. Clear warnings in the borrower's language are part of the app design.

## Loan purposes

The on-chain `sector` code doubles as the loan purpose, and each code has a plain-language name in every language (`loan.purpose.<code>` in `i18n/`). Because the code also drives the insurance basket's concentration cap, a drought that hits many farming loans at once cannot sink a basket.

| Code | Purpose |
|---|---|
| 1 | Stock for a shop or small business |
| 2 | Farming: seeds, fertiliser, irrigation |
| 3 | Livestock |
| 4 | School or university fees |
| 5 | Medical costs |
| 6 | Home repair or building |
| 7 | Tools or work equipment |
| 8 | Motorbike, rickshaw or vehicle for work |
| 9 | Emergency |
| 10 | Other business need |

## Open questions (economic design, founder decision)

1. **Repayment schedules that match real income.** For example a grace period before the first installment (a new shop, or a farm before harvest), or a single payment after harvest. The auction would price the longer risk; the waterfall is unchanged.
2. **Early repayment.** Today interest is fixed for the full term even if the borrower repays early. Should early payoff refund unearned interest?
3. **Local-currency loans.** They would remove the currency mismatch, but need trustworthy local-currency stablecoins and price feeds.
