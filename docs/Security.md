# Security

## Secret migration blocker

`.env` is a migration source only. It must not become the runtime Secret store.

- [ ] Inventory variable names without exposing values.
- [ ] Rotate credentials that were exposed or shared.
- [ ] Import required values into Vault Community.
- [ ] Replace application access with Secret references and policy.
- [ ] Remove plaintext values from shared files, history, logs and artifacts.
- [ ] Run Gitleaks against working tree and Git history.

P0 blocker means security release/promotion is blocked. It does not prevent safe documentation or isolated non-secret CI work.

## Access

- LLM may use Git and Secret Manager metadata/action APIs.
- LLM may not read, print, copy or log Secret values.
- Production policy, irreversible actions and release approval remain human-controlled.
