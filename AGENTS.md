# hyf - code directives

- this repo defines `hyf`, the contextual intelligence layer for Radroots networks; the primary daemon is `hyfd`
- treat this repo root as the source of truth for source, runtime behavior, repo-local release-candidate validation, and documentation
- official Radroots signed artifact provisioning, builder selection, target matrices, publication, promotion, and deploy transport are not defined by this repo
- keep docs and manifests honest about current implementation status and documented command surfaces
- prefer the smallest coherent change that fully addresses the request; do not mix unrelated cleanup, speculative refactors, or roadmap work into the same change
- read `README.md`, `pixi.toml`, and `flake.nix` before broad edits, and inspect the current implementation before changing behavior
- validate from this repo root with documented commands first; the current bootstrap smoke check is `pixi run run`
- `.github/**` and capsule-local CI workflows are forbidden; keep validation forge-agnostic, and place any required monorepo orchestration exclusively under the parent monorepo's root `.act/**` authority
- keep the service boundary as stdio rpc; `hyfd` is the canonical local process interface
- keep the service core in mojo; use the checked-in repo tooling surface for development, validation, and launch workflows
- if validation cannot run, report the blocker clearly instead of guessing past it
- toolchain: Mojo via the locally installed Modular toolchain
- prefer explicit typed models, deterministic behavior, and direct service boundaries over stringly or implicit behavior

## hyf_v1_jev specification execution

- Execute the owner-approved `hyf_v1_jev` handoff as a multi-RCLD sequence: one
  active slice at a time, one tested/reviewed/known-good commit per step. Do not
  merge, skip, reorder, broaden or auto-split steps.
- The durable governing document, decision register, step ledger and step
  evidence live under the parent monorepo `docs/` tree, not in this capsule:
  `docs/execution/rcl/hyf-v1-jev-multi-rcld-sequence.md`,
  `docs/execution/evidence/hyf_v1_jev/`.
- Per step record a report; allowed result states are `PLANNED`, `IN_PROGRESS`,
  `PASSED`, `FAILED`, `BLOCKED`, `NOT_RUN`, `NOT_APPLICABLE`. A step is `PASSED`
  only with executed evidence; never label an unrun source/model/provider check
  as passed.
- A deviation requires repository evidence recorded in the deviation ledger
  before proceeding; never silently skip or reorder.
- Conditional Cargo is `N/A — Mojo core` unless a real relevant Rust workspace
  is discovered.
- Stage only owned paths; never `git add -A`; never stage `secrets.txt`.
- Use `pixi run --frozen` for repo-owned tasks to avoid incidental lock rewrite.
