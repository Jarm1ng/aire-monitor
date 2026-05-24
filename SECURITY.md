# Security Notes

AIRE Monitor is designed as a local read-only monitoring tool.

Do not commit:

- passwords
- SSH private keys
- local `.ssh/config` files with personal aliases
- `.runtime/` cache files
- Slurm output or error logs that include private paths or research data

The application does not store passwords. Login credentials are passed to the local `expect` helper for the current login attempt only.

If you discover a sensitive-data exposure issue, remove the affected public data immediately and rotate any exposed credential.
