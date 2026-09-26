# Agent Instructions

- Never run rebuilds or builds (`nix build`, `nixos-rebuild`, `home-manager switch`, etc.). The user handles validation and activation.
- Do not run system-heavy checks or deep lookups unless explicitly asked (broad repo scans, nix store searches, long eval/build probes, exhaustive git history mining).
- Do not add code comments unless the user explicitly asks for them.
- Ignore `secrets/` and all sops stores completely. Do not read, write, edit, decrypt, or inspect encrypted secret files or key material.
- Put secrets in modules through sops-nix (`sops.secrets`, `config.sops.secrets.*.path`). Never hardcode secrets or bypass sops.
- Keep modules small and focused. Split large files, reuse shared helpers, and prefer minimal diffs over broad refactors.
- After editing Nix files, run `nixfmt` on the changed files.
- Do not add documentation files, README updates, or inline docs unless explicitly requested. Keep changes lean.
