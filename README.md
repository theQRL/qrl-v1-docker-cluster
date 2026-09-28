# qrl-cluster

Run a private, throwaway QRL network of several nodes on one machine, then check
that it actually works — not just that the containers started.

Built from the verification work that accompanied the 2026 modernisation of the
`qrl-docker` images. Every check here exists because the corresponding thing went
wrong at least once.

## Requirements

* Ubuntu (or any Linux) with Docker, and permission to use it
* `whiptail` for the menus — present on stock Ubuntu; plain prompts are used if absent
* `binutils` is optional, and enables one extra check

## Usage

```bash
./qrl-cluster.sh
```

That asks which images to use, how many nodes, how hard mining should be, how long
to run, and where to put the results. For unattended use:

```bash
./qrl-cluster.sh --yes --nodes 4 --versions noble,jammy --watch 10
```

| option | meaning |
|---|---|
| `--nodes N` | total nodes, spread across the chosen images |
| `--versions a,b,c` | which images, e.g. `noble,jammy,resolute` |
| `--difficulty N` | `genesis_difficulty`; lower mines faster (default 10000) |
| `--watch N` | minutes to run before the checks (default 10) |
| `--out DIR` | where results go (default: the directory you ran it from) |
| `--keep` | leave the cluster running afterwards |
| `--yes` | never prompt |

Exit status is 0 if every check passed, 1 otherwise, so it drops into CI unchanged.

## What it does

Creates a Docker network on a free `10.x.0.0/16` subnet, gives each node its own
volume and freshly generated mining address, writes each a config listing the
others as peers, and starts them on `--network-type testnet`. A live table shows
each node's height, peer count and sync state while it runs. Then it runs the
checks, writes a report, and removes everything.

Nodes are named `qrlc-<n>-<image>`, so you can tell at a glance which Ubuntu
release a given node is running.

## The checks, and why each one is there

**Every node still running, and none with exit code 132.** `132` is `SIGILL` — an
illegal instruction. Published images once required an AVX-512 CPU because a
dependency compiled with `-march=native`, which targets whatever machine ran the
build. They worked on the maintainer's server and died instantly on ordinary
desktops. An exit-132 node means the image is not built for your CPU.

**`wallet.json` is inside the volume.** The node's `--wallet_dir` defaults to `.`,
which with `WORKDIR /home/qrl` wrote the wallet into the container's own
filesystem — so `docker rm` silently destroyed it, funds included. The image sets
`ENV_QRL_WALLET_DIR` to prevent that, and this check proves it took effect.

**Identical block hash at a sampled depth.** Similar heights are not agreement.
Nodes can sit at the same height on different chains, and a fork only shows up if
you compare hashes. The sample is taken one block below the lowest tip, because
tips legitimately differ for a second or two while a block propagates — comparing
tips reports forks that are not there.

**Blocks were mined, by more than one node.** The historical crash was in the
mining path specifically, so a node that merely starts proves very little. At low
difficulty one node often wins every race; that is normal and reported as a note
rather than a failure.

**No AVX-512 instructions in the images** (amd64, needs `binutils`). Counts
EVEX-prefixed instructions, which in 64-bit mode are exclusively AVX-512. It
excludes matches **by symbol** rather than by how they disassemble: the byte at
`r4_add` is a RandomX JIT code template — data, not an instruction — and different
`objdump` builds render it as `<unknown>`, `.byte 0x62` or `(bad)`, so a
text-based filter silently misses it on some images.

## Output

```
qrl-cluster-20260927-182234/
├── report.md              summary table and pass/fail counts
├── qrlc-1-noble.yml       the exact config each node was given
├── qrlc-2-jammy.yml
└── logs/
    ├── qrlc-1-noble.log   full container logs
    └── qrlc-2-jammy.log
```

The configs are kept deliberately: if a run forks or fails to mine, the first
question is what the nodes were actually told to do.

## Notes

**Images by architecture.** `bionic` and `focal` are amd64 only — their
dependencies have never built for arm64. On an arm64 host the tool offers only
`jammy`, `noble` and `resolute`, and refuses an explicit `--versions bionic`
rather than failing obscurely later.

**Give it long enough.** RandomX spends two to three minutes building its dataset
before the first block. A `--watch` under 6 minutes will likely show no mining and
looks like a failure; the tool warns when you ask for less.

**Difficulty.** 10000 gives a block every minute or so on a modern machine with a
few nodes. Lower it for a faster test, raise it to make mining competitive between
nodes rather than won by the fastest.

**It is disposable.** Everything — containers, volumes, network, wallets — is
created fresh and destroyed at the end unless you pass `--keep`. The wallets hold
no real value; this is a private chain with its own genesis.

**Subnet choice.** The tool scans both host routes and existing Docker networks
before picking a subnet. Choosing blind can collide with the host's own network
and cut your connectivity, which is easier to do than it sounds.
