# oojq: House Laws & Agent Engineering Standards (v1)

This document is the **single canonical source of truth** for all code, architecture, and system integration standards across `oojq`. Every human contributor and AI agent must strictly follow these rules without exception.

---

## 1. The Page Rule (Code Layout & Sizing)

A **page** is one committed `.oo` or `.oot` file. Every page holds one idea, fits in one head, and carries its own weight. This rule is enforced by automated verification under `make verify`: red pages fail the build.

### Hard Sizing Invariants
- **16–256 Lines**: Every committed source file must be between **16 and 256 lines**, counted as exact line breaks (blank lines and comments count).
- **Shim Exemption (Floor Only)**: A file is a shim when every non-comment line is an import or re-export (`import "..."`). Shims skip the 16-line floor. The **256-line ceiling still strictly applies**.
- **Directory Density ($\le 8$ files)**: At most **8 `.oo` files per directory**, tests included. Crowded directories must split into functional subdirectories grouped by domain.
- **Banned File Names (Name the function, not the drawer)**:
  `util.oo`, `utils.oo`, `helper.oo`, `helpers.oo`, `common.oo`, `misc.oo`, `shared.oo`, `base.oo`, `core.oo`.

### Splitting, Folding, and Naming
- **Over 256 lines**: Split along functional boundaries into a new subdirectory with an `anchor.oo` shim. One page = one verb or one wholly owned noun.
- **Under 16 lines (and not a shim)**: Fold into its closest sibling or caller. Never pad lines with artificial whitespace or comments to reach 16.
- **Action pages lead with a verb**: `parse_stream.oo`, `eval_filter.oo`, `render_color.oo`.
- **State pages name what they own**: `json_doc.oo`, `filter_tree.oo`.
- **Boundary pages speak trust verbs**: `verify_token.oo`, `admit_node.oo`, `enforce_quota.oo`.

---

## 2. The 4-Element Academy Header (Mandatory on Every Page)

Every committed `.oo` file must begin with the standard 4-element Academy docstring within its first 7 lines:

```oo
// # Component Name - Subtitle
//
// Logline: Single-sentence imperative summary of functional responsibility.
//
// Setup: Preconditions, wired capability tokens, imported contracts.
//
// Beats:
//   1. First sequential phase of execution.
//   2. Next phase.
//   3. Final phase / exit state.
```

- **ASD-STE100 Compliance**: Clear, concise English. No filler or ambiguous verbs.
- **Imports**: All imports must be relative string literals (e.g. `import "render/render_color.oo";`). Never use `::` namespaces.

---

## 3. openOODA Capability & Zero-Trust Discipline

`oojq` operates strictly on the Object-Capability (OCap) security model:

### Unforgeable Capability Tokens
- **Zero Ambient Authority**: Privileged operations (reading inputs, process control) require explicit, unforgeable capability tokens passed as arguments (`&FsReadCap`, `&ProcessCap`, `&EnvCap`).
- **Read-Only by Construction**: JSON querying and transforming requires zero filesystem modification or network egress. Absence of `&FsWriteCap` and `&NetCap` in `main` is guaranteed.
- **Subprocess Safety**: Never invoke `/bin/sh -c` or `/bin/bash -c`. Direct binary execution must use explicit argv arrays via `ProcessCap`. Clean environment variables of child processes.
- **Arithmetic Safety**: Exact rational and arbitrary precision boundaries. Zero integer or floating-point leakage.

---

## 4. Unified Theming with `oote`

All openOODA tools synchronize visual presentation through `oote`:

- **Theme Resolver**: `oojq` hydrates JSON syntax tokens (`syntax_keyword`, `syntax_string`, `syntax_number`, `syntax_punct`) directly from `~/.openooda/theme.oot` or respects `OODA_THEME`, `OODA_MODE`, and `OODA_BORDER`.
- **Graceful Capability Degradation**: Automatically emits 24-bit TrueColor, degrades to 256 or 16-color ANSI, and suppresses all ANSI escapes under `NO_COLOR`, `OODA_NO_COLOR`, or `TERM=dumb`.

---

## 5. System Architecture: systemd & Tri-Distribution Compliance (Arch, Fedora, Debian)

All openOODA utilities adhere to a sovereign Linux architecture encompassing pure systemd citizenship and multi-distribution packaging parity across Arch Linux, Fedora, and Debian:

1. **Pure systemd-Native Citizenship**:
   - Manage services natively in `/etc/systemd/system/` (or `~/.config/systemd/user/` for user sessions).
   - Prefer drop-in overrides (`/etc/systemd/system/<unit>.service.d/*.conf`) for system/packaged units.
   - Declarative system accounts via `systemd-sysusers` in `/etc/sysusers.d/*.conf`.
   - Declarative directory ownership, permissions, and lifecycle rules via `systemd-tmpfiles` in `/etc/tmpfiles.d/*.conf`.
   - Service confinement and hardening via native directives (`ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp=true`, `NoNewPrivileges=true`).
   - Logging handled exclusively by `systemd-journald`. Scheduled tasks executed via `systemd.timer` units rather than legacy cron.
   - Standard system directories: `$RUNTIME_DIRECTORY` (`/run/openooda`), `$STATE_DIRECTORY` (`/var/lib/openooda`), `$CONFIGURATION_DIRECTORY` (`/etc/openooda`).

2. **Arch Linux Compliance (`pacman` / `makepkg`)**:
   - Upstream packaging maintained under `packaging/PKGBUILD` and `packaging/arch/PKGBUILD`.
   - Complies with Arch Packaging Standards: explicit metadata (`pkgname`, `pkgver`, `pkgrel`, `arch=('x86_64')`, `license=('Apache-2.0')`, `depends=('glibc')`).
   - Packages both `/usr/bin/oojq` and companion uninstaller `/usr/bin/oojq-uninstall` with mode `0755`.
   - Produces standard `.pkg.tar.zst` packages via `makepkg` or standard GNU `tar --zstd` with valid `.PKGINFO`.

3. **Fedora / RHEL Compliance (`dnf` / `rpmbuild`)**:
   - Spec files maintained under `packaging/oojq.spec`.
   - Complies with Fedora Packaging Guidelines: standard macros (`%{buildroot}`, `%{?dist}`, `%{SOURCE0}`), BuildArch `x86_64`, License `Apache-2.0`.
   - Packages both `/usr/bin/oojq` and `/usr/bin/oojq-uninstall` with explicit file ownership and changelog formatting.
   - Generates native RPM packages (`.rpm`) compatible with DNF and RPM.

4. **Debian / Ubuntu Compliance (`apt` / `dpkg-deb`)**:
   - Source packaging maintained under `packaging/debian/` (`control`, `changelog`, `copyright`, `rules`, `control.binary`).
   - Complies with Debian Policy: Section `utils`, Priority `optional`, Architecture `amd64`.
   - Installs both `oojq` and `oojq-uninstall` to `/usr/bin/` with mode `0755`.
   - Generates native Debian packages (`.deb`) compatible with APT and dpkg.

5. **Universal Installation & Clean Relinquishment**:
   - Universal `install.sh` must support distribution auto-detection and flags: `--dnf`, `--deb`, `--arch`/`--pacman`, `--dry-run`, and `--uninstall`.
   - Standalone binaries install to `/usr/local/bin` (or `~/.local/bin` for unprivileged installs).
   - Dedicated uninstaller `uninstall.sh` and companion CLI `oojq-uninstall` guarantee zero host residue upon removal.

6. **Exit Code Contract**: Strict jq parity:
   - `0`: Valid JSON parsed and transformed without errors.
   - `1`: Compile error or filter evaluation exception.
   - `2`: Bad usage or command line syntax error.
   - `3`: Input document invalid JSON.
   - `4`: Value evaluated to false or null (under `--exit-status` / `-e`).

---

## 6. Domain Architecture & Responsibilities

Work lands in exactly one domain at a time:

| Domain | Responsibility | Does NOT Do |
|---|---|---|
| `parse/` | JSON text to memory value tree (AST, lexical scanner) | Evaluate filters or render text |
| `filter/` | Filter expression compiler and execution engine | Touch filesystem or render formatting |
| `render/` | Transform evaluated value stream into JSON text, tables, or colors | Filter evaluation or parsing |
| `ipc/` | CLI options, MCP stdio server (`jq_query`) | Reimplement JSON parsing or filtering |

---

## 7. Verification & QA Gate

Before any commit or release is certified, the entire codebase must pass the automated verification gate:

1. **`make line-cap`**: Hard verification that 100% of `.oo` and `.oot` files are between 16 and 256 lines (shims exempt).
2. **`make file-law`**: Verification that no forbidden file extensions or stray documents are committed.
3. **`make academy`**: Verification that every source file contains the complete 4-element Academy header in its first 7 lines.
4. **`make density`**: Verification that no directory holds more than 8 pages.
5. **`make check`**: Full syntax and semantic verification via `oodac check` across every `.oo` page.
6. **`make parity`**: Byte-for-byte evaluation parity against jq test suites.
7. **`make test`**: 1,000+ behavioural tests across filter expressions, JSON parsing, and MCP stdio handling.
8. **Double-Run Determinism**: All verification runs execute twice sequentially in fresh processes ($Run_1 == Run_2$).
