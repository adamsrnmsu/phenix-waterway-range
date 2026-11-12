# provider/

`simulinksolver` is the process simulator behind the stock `bennu-simulink-provider` (see `waterway-sim/CONTRACT.md`).

- **Current:** built from the separate [ferrofire](~/git/ferrofire) repo (MIT): `./build-simulinksolver.sh` (set
  `FERROFIRE_DIR` if it is not at `~/git/ferrofire`). Same shm contract, same 15 waterway tags; the lock physics is now the
  model file `ferrofire/models/waterway.yaml` (embedded as the default, or drop a `model.yaml` next to the binary).
  Bead ww-1df.6; design in `docs/provider-spec.md`.
- **Legacy:** `waterway-sim/` (hand-written `physics.rs`) is kept until the range owner removes it;
  `SOLVER=legacy ./build-simulinksolver.sh` still builds it. Ferrofire's output was verified identical to it
  (600 s trace, max abs diff 0).

Both write `waterway-sim/dist/simulinksolver`; then `cp` it to `topologies/waterway-arm64/injects/` as in the top-level README.
