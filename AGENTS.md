# hyf - code directives

- this repo defines `hyf`, the contextual intelligence layer for Radroots networks; the primary daemon is `hyfd`
- treat this repo root as the source of truth for runtime, release, validation, and documentation
- keep docs and manifests honest about current implementation status and documented command surfaces
- prefer the smallest coherent change that fully addresses the request; do not mix unrelated cleanup, speculative refactors, or roadmap work into the same change
- read `README.md`, `pixi.toml`, and `flake.nix` before broad edits, and inspect the current implementation before changing behavior
- validate from this repo root with documented commands first; the current bootstrap smoke check is `pixi run run`
- keep the service boundary as stdio rpc; `hyfd` is the canonical local process interface
- keep the service core in mojo; use the checked-in repo tooling surface for development, validation, and launch workflows
- if validation cannot run, report the blocker clearly instead of guessing past it
- toolchain: Mojo via the locally installed Modular toolchain
- prefer explicit typed models, deterministic behavior, and direct service boundaries over stringly or implicit behavior
