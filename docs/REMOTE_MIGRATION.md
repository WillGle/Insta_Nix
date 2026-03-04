# Remote Migration Runbook

This repo provides two outputs for remote safety:

- `Think14GRyzen-bootstrap`: temporary dual-access SSH (`22` + `2222`, root key login allowed, no password auth)
- `Think14GRyzen`: final strict SSH (`2222` only, root login disabled)

## Flow

1. Boot target machine into NixOS installer with SSH enabled.
2. Install bootstrap profile:

```bash
npx nixos-anywhere --flake .#Think14GRyzen-bootstrap root@<ip>
```

3. Verify user access:

```bash
ssh -p 2222 will@<ip>
```

4. Switch to strict profile:

```bash
sudo nixos-rebuild switch --flake /etc/nixos#Think14GRyzen
```

5. Re-verify:

```bash
ssh -p 2222 will@<ip>
```

## Notes

- Password authentication is disabled in both profiles.
- Keep at least one working SSH public key configured before enforcing strict mode on new hosts.
