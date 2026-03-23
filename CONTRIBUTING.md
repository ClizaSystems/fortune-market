# Contributing

## Local setup

```bash
cp .env.example .env
npm install
npm run compile
npm run test:fast
```

Use `npm run test:fork` when you want the Base fork lifecycle coverage and have `BASE_RPC_URL` set.

## Pull requests

- Keep changes scoped and explain the user-visible or protocol-level effect.
- Add or update tests for any behavior change.
- Regenerate `docs/fortune-vs-traditional-scenarios.svg` when simulator output changes.
- Do not commit secrets, funded keys, or private RPC URLs.

## Style

- Solidity and TypeScript should stay strict, minimal, and contract-first.
- Prefer small commits that leave the repo in a buildable state.
