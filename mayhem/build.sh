#!/usr/bin/env bash
#
# mp4parse-rust/mayhem/build.sh — build the cargo-fuzz targets (upstream's own
# mp4parse_capi/fuzz crate: `mp4` and `avif`) as sanitized libFuzzer binaries
# (OSS-Fuzz Rust path: cargo-fuzz + ASan via RUSTFLAGS), plus the project's OWN
# test suites (normal flags) so mayhem/test.sh only RUNS them.
#
# Runs inside the commit image (RUST mayhem/Dockerfile) as `mayhem` in /mayhem.
# Toolchain + cargo registry live at $CARGO_HOME=/opt/toolchains/rust/cargo.
#
# AIR-GAPPED CONTRACT (SPEC §6.5): the PATCH tier re-runs THIS script OFFLINE.
# The first (online) run populates the cargo registry cache under $CARGO_HOME;
# the offline re-run resolves everything from that cache (the rlenv runtime
# exports CARGO_NET_OFFLINE=true — do NOT hard-code --offline here).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${MAYHEM_JOBS:=$(nproc)}"
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

cd "$SRC"

# ── 1. Sanitized fuzz targets: cargo-fuzz + ASan via RUSTFLAGS ─────────────────
# Debug-info contract (§6.2 item 10): Mayhem triage needs DWARF < 4 and rustc's
# default is DWARF-5 — pin version 3. ASan for the Rust code comes via
# -Zsanitizer=address (cargo-fuzz's analogue of the C $SANITIZER_FLAGS contract).
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -Z dwarf-version=3}"
FUZZ_RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing -Zsanitizer=address $RUST_DEBUG_FLAGS"
# libfuzzer-sys compiles the C++ libFuzzer runtime via the cc crate — pin its
# debug info to DWARF-3 too (clang's plain -g emits DWARF-5).
export CFLAGS="${CFLAGS:-} -gdwarf-3"
export CXXFLAGS="${CXXFLAGS:-} -gdwarf-3"
# rustc ships a prebuilt ASan runtime (compiler-rt) carrying DWARF-5 CUs; strip
# its debug info before linking so the final binary stays DWARF < 4 throughout
# (sanitizer symbolication uses the runtime's symtab, not its DWARF). Idempotent.
for rt in "$(rustc --print target-libdir)"/librustc-*_rt.asan.a; do
  if [ -e "$rt" ]; then objcopy --strip-debug "$rt"; fi
done

FUZZ_DIR="mp4parse_capi/fuzz"
TRIPLE="x86_64-unknown-linux-gnu"

FUZZ_TARGETS=()
for f in "$FUZZ_DIR"/fuzz_targets/*.rs; do
  FUZZ_TARGETS+=("$(basename "${f%.*}")")
done
[ "${#FUZZ_TARGETS[@]}" -gt 0 ] || { echo "ERROR: no fuzz targets under $FUZZ_DIR/fuzz_targets/" >&2; exit 1; }

echo "=== cargo fuzz build (image nightly, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$FUZZ_RUSTFLAGS"
echo "targets: ${FUZZ_TARGETS[*]}"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  RUSTFLAGS="$FUZZ_RUSTFLAGS" cargo fuzz build --build-std --strip-dead-code --fuzz-dir "$FUZZ_DIR" -O --debug-assertions "$t"
  bin="$SRC/$FUZZ_DIR/target/$TRIPLE/release/$t"
  [ -x "$bin" ] || { echo "ERROR: expected fuzz binary not found at $bin" >&2; exit 1; }
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

# ── 2. Fetch the git submodule test assets (av1-avif, link-u sample images) ───
# mp4parse's integration tests (tests/public.rs) read hundreds of real AVIF/MP4
# assets that live in two git submodules (see .gitmodules). Upstream CI checks
# out with `submodules: recursive`; a bare clone only has the gitlinks. Fetch
# them here (online, during the commit build) so the assets are baked into the
# image and mayhem/test.sh runs fully OFFLINE. Idempotent + air-gapped: guarded
# on the submodule dir being empty, so the PATCH re-run (offline) is a no-op.
if [ -f .gitmodules ] && [ -z "$(ls -A mp4parse/av1-avif 2>/dev/null)" ]; then
  echo "=== fetching test-asset submodules ==="
  git submodule update --init --recursive --depth 1
fi

# ── 3. The project's OWN test suites (NORMAL flags — clean, non-sanitized) ─────
# Upstream CI (.github/workflows/build.yml) runs, per feature set:
#   cargo test --all --features ""                       (default features)
#   cargo test --all --features "missing-pixi-permitted"
# (plus release-mode repeats of the same tests, and fmt/clippy lints).
# Compile both feature sets here; mayhem/test.sh executes them without rebuilding.
echo "=== building the upstream test suites (normal flags) ==="
cargo test --no-run --all
cargo test --no-run --all --features missing-pixi-permitted

echo "build.sh complete"
