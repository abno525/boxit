#!/usr/bin/env bash
# boxit live probe: checks how your real Incus behaves, for the things the fake-incus
# tests can't show. Run it on the machine that runs boxit, then paste the output back.
#
# It creates two throwaway VMs (boxit-probe-a, boxit-probe-b) cloned from boxit-base,
# a throwaway ACL (boxit-probe-acl) and a folder ~/.boxit-probe.XXXX, and deletes all of
# them at the end, also on errors or Ctrl-C. It doesn't change boxit's own ACL, profile
# or VMs. For a few seconds it serves an empty folder on host port 18080 (all addresses)
# and 19091 (localhost only). Takes a few minutes; output is also saved to $OUT.
set -uo pipefail

A=boxit-probe-a B=boxit-probe-b PACL=boxit-probe-acl BRIDGE=incusbr0
OUT=${TMPDIR:-/tmp}/boxit-probe.txt
exec > >(tee "$OUT") 2>&1

T= Bok=1 HPIDS=()
H() { printf '\n=== %s\n' "$*"; }
# r CMD...: show a command, its output (indented) and its exit code; returns that code.
r() {
	local rc
	printf '$ %s\n' "$*"
	"$@" 2>&1 | sed 's/^/    /'
	rc=${PIPESTATUS[0]}
	printf '    [exit %s]\n' "$rc"
	return "$rc"
}
up() {
	local _
	for _ in $(seq 120); do incus exec "$1" -- true >/dev/null 2>&1 && return 0; sleep 1; done
	echo "    $1 did not come up"
	return 1
}
ipv4() {
	local _ ip
	for _ in $(seq 60); do
		# Any interface: inside the guest the card is enp5s0 or similar, not eth0.
		ip=$(incus query "/1.0/instances/$1/state" | jq -r '[.network[]? | .addresses[]? | select(.family == "inet" and .scope == "global") | .address][0] // empty')
		[[ -n $ip ]] && { echo "$ip"; return 0; }
		sleep 1
	done
	echo none
}
serve_in() { # VM PORT BIND: background web server in the VM serving an empty folder
	incus exec "$1" -- sh -c "mkdir -p /tmp/empty && setsid -f python3 -m http.server $2 --bind $3 --directory /tmp/empty >/dev/null 2>&1 </dev/null"
}
http() { curl -sS -m "${2:-5}" -o /dev/null -w '%{http_code}\n' "$1"; }
cleanup() {
	H "cleanup"
	[[ -n $T && -S $T/sock ]] && ssh -S "$T/sock" -O exit agent@boxit >/dev/null 2>&1
	for p in "${HPIDS[@]}"; do kill "$p" 2>/dev/null; done
	# Root-owned files in A's folder can only be removed from inside A.
	[[ -n $T ]] && incus exec "$A" -- sh -c 'rm -rf /work/* /work/.[!.]*' >/dev/null 2>&1
	incus delete --force "$A" >/dev/null 2>&1
	incus delete --force "$B" >/dev/null 2>&1
	incus network acl delete "$PACL" >/dev/null 2>&1
	if [[ -n $T && -d $T ]]; then
		rm -rf "$T" 2>/dev/null || echo "    could not remove $T (root-owned files left?): sudo rm -rf '$T'"
	fi
	echo "    done. Output saved to $OUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

for c in incus jq ssh ssh-keygen python3 curl ip; do
	command -v "$c" >/dev/null || { echo "missing on the host: $c"; exit 1; }
done
# Only for the last check; some distributions keep it in /usr/sbin, outside a user's PATH.
BRIDGE_CMD=$(command -v bridge || ls /usr/sbin/bridge /sbin/bridge 2>/dev/null | head -1)
incus query /1.0/instances/boxit-base/snapshots/ready >/dev/null 2>&1 ||
	{ echo "boxit-base/ready not found: run boxit once in any project folder first"; exit 1; }
# Leftovers from an earlier probe run.
incus delete --force "$A" >/dev/null 2>&1
incus delete --force "$B" >/dev/null 2>&1
incus network acl delete "$PACL" >/dev/null 2>&1

H "1. environment"
r incus version
for k in ipv4.address ipv4.nat ipv6.address ipv6.nat; do r incus network get "$BRIDGE" "$k"; done
r ip -o addr show scope global
r sh -c 'lsmod | grep -E "^br_netfilter" || echo "br_netfilter not loaded"'
r sh -c 'command -v virtiofsd; ls -l /usr/libexec/virtiofsd /usr/lib/virtiofsd /usr/lib/qemu/virtiofsd 2>/dev/null; true'
r sh -c 'incus query /1.0/network-acls/boxit-egress | jq -c ".egress[]"'
r incus profile show boxit

H "2. ACL rule syntax, on a throwaway ACL"
r incus network acl create "$PACL"
r incus network acl rule add "$PACL" egress action=reject destination=::/0
r incus network acl rule add "$PACL" egress action=allow
r sh -c "incus query /1.0/network-acls/$PACL | jq -c '.egress[]'"
r incus network acl delete "$PACL"

H "3. two throwaway VMs: A = share as today, B = share with raw.idmap + io.bus=virtiofs"
T=$(mktemp -d "$HOME/.boxit-probe.XXXX")
mkdir -p "$T/a" "$T/b" "$T/empty"
U=$(id -u) G=$(id -g)
if [[ $U == "$G" ]]; then IDMAP="both $U 1000"; else IDMAP=$(printf 'uid %s 1000\ngid %s 1000' "$U" "$G"); fi
echo "    host uid=$U gid=$G; raw.idmap for B: $(printf '%q' "$IDMAP")"
r incus copy boxit-base/ready "$A"
r incus config device add "$A" work disk source="$T/a" path=/work
r incus copy boxit-base/ready "$B" -c raw.idmap="$IDMAP"
r incus config device add "$B" work disk source="$T/b" path=/work io.bus=virtiofs
r incus start "$A" && up "$A" || { echo "A did not start; stopping here"; exit 1; }
r incus start "$B" && up "$B" && Bok=0
r sh -c "incus query /1.0/instances/$B | jq -c '{idmap: .config[\"raw.idmap\"], work: .expanded_devices.work, eth0: .expanded_devices.eth0}'"
r incus exec "$A" -- findmnt -no FSTYPE,OPTIONS /work
((Bok == 0)) && r incus exec "$B" -- findmnt -no FSTYPE,OPTIONS /work

H "3b. running programs from /work (you saw 'bad interpreter: Bad address' there)"
printf '#!/bin/sh\necho host-script-ok\n' >"$T/a/host.sh" && chmod +x "$T/a/host.sh" && cp "$T/a/host.sh" "$T/b/host.sh"
probe_exec() { # VM HOSTDIR
	r incus exec "$1" -- uname -r
	r incus exec "$1" --user 1000 --group 1000 -- /work/host.sh
	r incus exec "$1" --user 1000 --group 1000 -- sh /work/host.sh
	r incus exec "$1" --user 1000 --group 1000 -- sh -c 'printf "#!/bin/sh\necho vm-script-ok\n" >/work/vm.sh && chmod +x /work/vm.sh && /work/vm.sh'
	r incus exec "$1" --user 1000 --group 1000 -- sh -c 'cp /bin/echo /work/echo-bin && /work/echo-bin binary-ok'
	r incus exec "$1" --user 1000 --group 1000 -- sh -c 'cp /work/host.sh /tmp/host.sh && /tmp/host.sh'
	rm -f "$2/host.sh" "$2/vm.sh" "$2/echo-bin"
}
echo "--- A (share as today)"
probe_exec "$A" "$T/a"
if ((Bok == 0)); then
	echo "--- B (raw.idmap, virtiofs)"
	probe_exec "$B" "$T/b"
fi

H "4. issue 4: what can root in the VM create in the shared folder?"
probe_files() { # VM HOSTDIR
	r incus exec "$1" -- touch /work/root-file
	r incus exec "$1" -- sh -c 'cp /bin/true /work/suid-root && chmod 4755 /work/suid-root'
	r incus exec "$1" -- mknod /work/dev-root c 1 3
	r incus exec "$1" -- setpriv --reuid=1000 --regid=1000 --clear-groups \
		--inh-caps=+mknod --ambient-caps=+mknod mknod /work/dev-uid1000 c 1 3
	r incus exec "$1" --user 1000 --group 1000 -- sh -c 'touch /work/user-file && cp /bin/true /work/suid-user && chmod 4755 /work/suid-user'
	r incus exec "$1" -- chown 0:0 /work/user-file
	echo "    on the host:"
	(cd "$2" && stat -c '    %n: uid=%u gid=%g mode=%A type=%F' -- * 2>&1)
}
echo "--- A (no mapping)"
probe_files "$A" "$T/a"
r incus exec "$A" -- sh -c 'rm -rf /work/*'
if ((Bok == 0)); then
	echo "--- B (raw.idmap)"
	probe_files "$B" "$T/b"
fi

H "5. issue 5: can A reach B over the bridge? (no isolation settings yet)"
AIP=$(ipv4 "$A")
echo "    A=$AIP"
if ((Bok == 0)); then
	serve_in "$B" 8000 0.0.0.0
	BIP=$(ipv4 "$B")
	echo "    B=$BIP"
	r incus exec "$B" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/
	r incus exec "$A" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://$BIP:8000/"
fi
r incus exec "$A" -- curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://example.com/
r incus exec "$A" -- getent hosts example.com

H "6. issue 3: IPv6 from A, and A to the host's own addresses"
r incus exec "$A" -- ip -6 addr show scope global
r incus exec "$A" -- curl -6 -sS -m 10 -o /dev/null -w '%{http_code}\n' https://ipv6.google.com/
python3 -m http.server 18080 --bind :: --directory "$T/empty" >/dev/null 2>&1 &
HPIDS+=($!)
sleep 1
r http http://127.0.0.1:18080/
for ip in $(ip -6 -o addr show scope global | awk '{print $4}' | cut -d/ -f1); do
	r incus exec "$A" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://[$ip]:18080/"
done
for ip in $(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1); do
	r incus exec "$A" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://$ip:18080/"
done

H "7. port forwarding design: ssh over incus exec, both directions (in A)"
r incus exec "$A" -- sh -c 'export DEBIAN_FRONTEND=noninteractive
	apt-get update -q >/dev/null && apt-get install -y -q openssh-server >/dev/null || exit 1
	systemctl disable --now ssh.socket ssh.service >/dev/null 2>&1
	command -v sshd; ls /etc/ssh/ssh_host_*_key; ss -ltn | grep -c ":22 " || true'
ssh-keygen -q -t ed25519 -N '' -C boxit-probe -f "$T/key"
r incus file push --uid 0 --gid 0 --mode 0644 -p "$T/key.pub" "$A/etc/boxit/authorized_keys"
incus exec "$A" --user 1000 --group 1000 -- sh -c 'mkdir -p /tmp/empty && setsid -f python3 -m http.server 19090 --bind 127.0.0.1 --directory /tmp/empty >/dev/null 2>&1 </dev/null'
python3 -m http.server 19091 --bind 127.0.0.1 --directory "$T/empty" >/dev/null 2>&1 &
HPIDS+=($!)
sleep 1
SSHD_OPTS='-o AuthorizedKeysFile=/etc/boxit/authorized_keys -o AllowUsers=agent -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o AllowTcpForwarding=yes -o GatewayPorts=no -o PermitTTY=no -o X11Forwarding=no -o AllowAgentForwarding=no -o LogLevel=ERROR'
PROXY="incus exec $A -T -- sh -c 'mkdir -p /run/sshd && exec /usr/sbin/sshd -i $SSHD_OPTS'"
SSH=(ssh -F /dev/null -f -N -a -x -i "$T/key" -o IdentitiesOnly=yes -o IdentityAgent=none
	-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
	-o ExitOnForwardFailure=yes -o ProxyCommand="$PROXY")
# Not through r(): a backgrounded ssh would keep r's pipe open.
echo '$ ssh ... -M -S sock -L 127.0.0.1:19090:localhost:19090 -R 127.0.0.1:19091:localhost:19091'
"${SSH[@]}" -M -S "$T/sock" -L 127.0.0.1:19090:localhost:19090 -R 127.0.0.1:19091:localhost:19091 agent@boxit 2>"$T/ssh.err"
echo "    [exit $?]"
sed 's/^/    /' "$T/ssh.err"
r http http://127.0.0.1:19090/
r incus exec "$A" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19091/
r sh -c "pgrep -af '[i]ncus exec $A ' || echo 'no process matches'"
echo '$ ssh ... -L 127.0.0.1:19091:... (host port already in use; should fail)'
"${SSH[@]}" -S "$T/sock2" -M -L 127.0.0.1:19091:localhost:1 agent@boxit 2>"$T/ssh2.err"
echo "    [exit $?]"
sed 's/^/    /' "$T/ssh2.err"
r ssh -S "$T/sock" -O exit agent@boxit

H "8. issue 5: isolation settings on the network cards"
r incus stop "$A"
r incus config device override "$A" eth0 security.port_isolation=true security.ipv4_filtering=true
r incus start "$A" && up "$A"
echo "    A=$(ipv4 "$A")"
r incus exec "$A" -- curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://example.com/
if ((Bok == 0)); then
	r incus stop "$B"
	r incus config device override "$B" eth0 security.port_isolation=true security.ipv4_filtering=true security.ipv6_filtering=true
	if ! { r incus start "$B" && up "$B"; }; then
		echo "    retrying B without security.ipv6_filtering"
		r incus config device unset "$B" eth0 security.ipv6_filtering
		r incus start "$B" && up "$B"
	fi
	serve_in "$B" 8000 0.0.0.0
	BIP=$(ipv4 "$B")
	echo "    B=$BIP"
	r incus exec "$B" -- curl -sS -m 10 -o /dev/null -w '%{http_code}\n' https://example.com/
	r incus exec "$A" -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' "http://$BIP:8000/"
fi
for v in "$A" "$B"; do
	tap=$(incus query "/1.0/instances/$v/state" 2>/dev/null | jq -r '[.network[]? | .host_name // empty | select(. != "")][0] // empty')
	if [[ -z $BRIDGE_CMD ]]; then echo "    (no bridge command on the host; skipping the isolation flag check)"
	elif [[ -n $tap ]]; then r "$BRIDGE_CMD" -d link show dev "$tap"; fi
done
