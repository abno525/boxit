# boxit

Run a command in an Incus VM that can only see the current folder.

```
boxit [CMD ARGS...]         # run CMD in this folder's VM (no CMD = bash shell), folder mounted at /work
boxit --port SPEC [CMD...]  # also forward localhost:PORT here to localhost:PORT in the VM (repeatable)
boxit --reverse-port SPEC   # also forward localhost:PORT in the VM to localhost:PORT here (repeatable)
boxit --list                # VMs created by boxit: NAME  STATE  FOLDER
boxit --rm [NAME|PATH..]    # delete VM(s) (default: this folder's), asks y/N; folder files stay
boxit -- CMD...             # run a command whose name starts with '-'
```

Example: `cd ~/code/myproj && boxit claude`

## Ports
- `boxit --port 9090 claude`: `localhost:9090` on your machine reaches `localhost:9090` inside the VM, for example to open a dev server running in the VM in your browser.
- `boxit --reverse-port 5432 claude`: `localhost:5432` inside the VM reaches `localhost:5432` on your machine, for example a database you run on the host. This deliberately gives the VM that one port on your machine.
- SPEC is `PORT` (short for `PORT:localhost:PORT`) or `LISTENPORT:HOST:PORT`, as with `ssh -L`/`-R`. The listening side is always `127.0.0.1`. HOST is looked up on the far side: inside the VM for `--port`, on your machine for `--reverse-port`.
- The forwards last while that `boxit` command runs. If a port is already taken, `boxit` says so and doesn't run the command.
- How: `ssh` over `incus exec` into `sshd -i` in the VM, with a key in `~/.config/boxit/ssh_key`. Nothing listens on port 22 in the VM, the forwards don't go through the VM's network (so the ACL below is unaffected), and your own ssh config and agent aren't used.

## How it works
- **One VM per folder** (`boxit-<folder>-<hash>`), reused on later runs, so packages you install and Claude's history persist. The folder is mounted at `/work` (virtiofs).
- **File ownership:** the VM user `agent` (UID/GID 1000) is mapped to your own UID/GID on the host, whatever they are, and every other ID is refused (Incus `raw.idmap`). `agent` has passwordless sudo inside the VM, but root there can't create or chown files in `/work`: it gets "Input/output error". So nothing in the VM can leave root-owned or setuid-root files or device nodes in your folder. VMs made by an older boxit get the mapping on their next start. If such a VM is already running, `boxit` asks you to exit its other sessions first. At that point it also points out any files in the folder that aren't yours.
- **The VM stops** when the last `boxit` session in it exits. The next run boots it again in a few seconds.
- **Base image:** the first run builds `boxit-base` from `images:ubuntu/24.04`. It has git, curl, build-essential, python3, jq, ripgrep, openssh-server (only for `--port`; not running), Claude Code, and Ubuntu's newer HWE kernel. The default 24.04 kernel (6.8) can't run programs straight from `/work` ("Bad address"), and `boxit` points this out when it boots a VM that still has it. New VMs are copy-on-write clones of the base's `ready` snapshot. To rebuild it: `boxit --rm boxit-base`, and the next run builds a fresh one. Existing VMs keep their own copy, and Claude updates itself inside each VM.
- **Claude login:** if `~/.config/boxit/claude-oauth-token` exists (a `claude setup-token` token), it's copied into the VM on each start and exported as `CLAUDE_CODE_OAUTH_TOKEN`, so there's no login per VM.
- **Network:** internet goes out through `incusbr0` (NAT), IPv4 only. The Incus ACL `boxit-egress` rejects the host and LAN (`10/8 172.16/12 192.168/16 169.254/16 100.64/10`) and all IPv6, and allows the rest; Incus applies reject rules before allow rules. All of IPv6 is rejected because your host's and LAN's global IPv6 addresses can't be listed ahead of time. IPv6 is also turned off inside the VM, so programs don't try it first. DNS through the bridge still works.
- **Isolation:** boxit VMs can't talk to each other at all (`security.port_isolation`), and none can pretend to be another instance on the bridge (`security.ipv4_filtering`/`ipv6_filtering` block spoofed MAC, ARP and IP). Other instances on `incusbr0` are out of reach because their addresses are inside the rejected ranges. Every run checks that `incusbr0`'s subnet still is, and refuses to go on otherwise.
- **Fails closed:** the VM's network card rejects any traffic the ACL doesn't allow, so if the ACL is ever empty or half made, the VM has no network rather than an open one. Every run puts back any missing ACL rule before a VM starts, and refuses to go on if one of the VM's network cards doesn't use the ACL this way or isn't isolated (for example after editing the `boxit` profile or adding a card to one VM). A `boxit` profile made by an older version is switched over automatically.
- **Resources** come from the Incus profile `boxit`: 4 CPUs, 8 GiB RAM, 20 GiB disk. Change them with `incus profile set boxit limits.memory=12GiB` and similar.

## Limits
- Anything inside the VM can read and change everything in the mounted folder, including `.git/hooks`. Review those before you run git on the host.
- Anything in the VM can read the Claude token.
- The VM has full outbound IPv4 internet; nothing filters what it sends.
- If your host has a public IPv4 address directly on an interface (a server, not a machine behind a home router), the VM can reach services listening on it.
- Something in the VM can leave symlinks in the folder that point at files on your machine (`~/.bashrc`, say). That's harmless until a program on the host follows one and writes through it, the same kind of risk as `.git/hooks`.
- `--reverse-port` gives the VM the host port you name.
- `boxit` refuses to run in `/` or `$HOME`.

## Tests
- `tests/run.sh` tests `boxit` against a fake `incus` and `ssh` (in `tests/bin`); it doesn't touch your Incus.
- `tests/live/probe.sh` checks how your real Incus behaves, using throwaway VMs it deletes again.
