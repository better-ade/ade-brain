# V4: Docker is installed with the hub, for isolated local tests (local SIT)

Status: **Approved** (owner, 2026-11-25). Risk: **high** (`bin/server install` changes a server, and
membership of the `docker` group is root-equivalent on Linux).
Found by: the owner wants developers to run isolated system integration tests locally, in containers.
Verification: `bash tests/run.sh`.

## Goal
Docker is part of the hub's tool set, like `age` (story I4): `bin/setup` and `bin/doctor` report it, and the install
steps install it. It is **recommended, not needed**: a missing Docker is a warning, never a failure, because many hubs
never run containers.

- **macOS:** `brew install colima docker docker-compose` (the free, headless engine; Docker Desktop is not required
  and needs a paid licence in larger companies). If `docker` already works (Docker Desktop, OrbStack), nothing is
  installed.
- **Linux / `bin/server install`:** the distribution's `docker.io` and `docker-compose-v2` from apt, and the service
  enabled. The hub's user is **not** added to the `docker` group automatically (that is root-equivalent): the install
  prints the one command to do it, and `bin/doctor` says when the daemon is there but this user can't reach it.
- `bin/doctor`: `OK docker <version>` when `docker info` works; `WARN docker` with the install line (or the group
  command, or "start colima") otherwise.
- `bin/setup`: one warning line when Docker is missing, then goes on.

## Acceptance criteria (tests stub `docker`, `colima`, `brew` and `apt-get`; no real install in tests)
1. `bin/doctor` on macOS and Linux: OK when `docker info` works; WARN with this platform's install line when `docker`
   is missing; WARN naming the group command when the daemon refuses this user. Doctor's exit code is unchanged by
   any of them.
2. `bin/setup` prints one Docker warning when it is missing and still exits 0.
3. `bin/server install` (tests/test_server.sh): `docker.io` and `docker-compose-v2` are in the package list, the
   service is enabled, and no `usermod`/`gpasswd` is run; the group command is printed.
4. The Homebrew step names `colima docker docker-compose`, and installs nothing when `docker` already works.
5. `.ade/context/server.md`, the README's install section and `docs/index.html` name Docker as recommended.

## Out of scope
Writing SIT suites or compose files for any project (each project's own story). Kubernetes. Rootless Docker or
Podman (a later story if wanted). Running the hub itself in a container.
