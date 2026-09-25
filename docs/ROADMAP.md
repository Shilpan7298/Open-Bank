# Roadmap

## Phase 1: testnet MVP (now)

Everything runs on local Anvil. No real funds.

Done:
- All protocol contracts, with unit, fuzz, invariant and end-to-end tests
- The AI underwriter: multilingual, with a mock mode
- Translation catalogs in English, Arabic, Bengali and Spanish

Next:
- Native-speaker review of the Arabic, Bengali and Spanish catalogs
- Insurance basket capital earning base yield (IB-13)
- Handling late loans: freeze insurer withdrawals and mark down lender vault positions
- Recovery after default, paid back in reverse waterfall order
- Monte Carlo simulation in `sim/`, including currency devaluation and country shocks; tune launch parameters
- Security review of every contract

## Phase 2: public testnet (Base Sepolia)

- Real EAS attestations and a zkTLS attestation issuer for income and bank-history proofs
- A mobile-first web app that works on cheap Android phones and slow connections, with right-to-left layouts and every string from `i18n/`
- Local-currency display of amounts; Chainlink price feeds where needed
- Kleros dispute hook for small disputes
- Community translation of the app into the ten most requested languages

## Phase 3: mainnet (only after audits and legal structure)

- Independent audits, then a bug bounty
- A legal entity, a Ricardian agreement template per jurisdiction, and per-country legal review of stablecoin lending
- Governance with a TimelockController and a guardian, then broader community governance
- Partnerships with local community organisations for onboarding, and a humanitarian route through licensed institutions where needed
