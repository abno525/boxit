#!/usr/bin/env bash
# End-to-end check of boxit against your real Incus. Uses the boxit next to this folder
# and a throwaway project folder ~/.boxit-verify.XXXX, whose VM it deletes at the end
# (also on errors or Ctrl-C). For about a minute it serves an empty folder on port 18080
# (all addresses) and 19091 (localhost only). Takes a few minutes, more if the base image
# has to be built first. Output is also saved to /tmp/boxit-verify.txt.
set -uo pipefail

BOXIT=$(cd "$(dirname "$0")/../.." && pwd -P)/boxit
OUT=/tmp/boxit-verify.txt
exec > >(tee "$OUT") 2>&1

npass=0 nfail=0 W= D= HPIDS=()
ok() { echo "  ok   $*"; npass=$((npass + 1)); }
bad() { echo "  FAIL $*"; nfail=$((nfail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
# bx ARGS...: run boxit in the project folder; its messages go to $W/err (shown indented).
bx() {
	local rc
	(cd "$D" && "$BOXIT" "$@") 2>"$W/err"
	rc=$?
	sed 's/^/    | /' "$W/err" >&2
	return "$rc"
}
vm() { incus list --format json | jq -r --arg p "$D" '.[] | select(.config["user.boxit.path"] == $p) | .name'; }
cleanup() {
	echo "== cleanup"
	for p in "${HPIDS[@]}"; do kill "$p" 2>/dev/null; done
	if [[ -n $D && -d $D ]]; then
		(cd "$D" && echo y | "$BOXIT" --rm) >/dev/null 2>&1
		rm -rf "$W"
	fi
	echo
	echo "passed $npass, failed $nfail. Output saved to $OUT"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

W=$(mktemp -d "$HOME/.boxit-verify.XXXX")
D=$W/proj
mkdir -p "$D" "$W/empty"
echo "boxit: $BOXIT"
echo "folder: $D"

echo "== 1. first run (builds the base image first if there is none: a few minutes)"
out=$(bx sh -c 'echo hello')
check "runs a command in the VM" [ "$out" = hello ]
check "no old-kernel note" bash -c '! grep -q "runs kernel" "$1"' _ "$W/err"
name=$(vm)
echo "    VM: $name"

# Keep one session open so the VM stays up between the checks instead of booting each time.
(cd "$D" && "$BOXIT" sh -c 'while [ ! -e /work/.verify-done ]; do sleep 1; done') 2>"$W/keeper.err" &
keeper=$!
sleep 3

echo "== 2. a second run changes nothing"
bx true
rc=$?
check "exit 0" [ $rc = 0 ]
check "doesn't stop the VM while another session uses it" bash -c '! grep -q "stopping" "$1"' _ "$W/err"
check "no setup or upgrade messages" bash -c '! grep -qE "missing the rule|on eth0|mapping IDs|creating|installing|note:" "$1"' _ "$W/err"

echo "== 3. the folder"
out=$(bx sh -c 'printf "#!/bin/sh\necho script-ok\n" >t.sh && chmod +x t.sh && ./t.sh')
check "a script in /work runs directly" [ "$out" = script-ok ]
check "a file made in the VM is yours on the host" [ "$(stat -c %u:%g "$D/t.sh")" = "$(id -u):$(id -g)" ]
bx sudo touch /work/rootfile
check "root in the VM can't create a file in /work" [ ! -e "$D/rootfile" ]
bx sudo chown root:root /work/t.sh
check "...or make yours root's" [ "$(stat -c %u "$D/t.sh")" = "$(id -u)" ]
bx sudo mknod /work/dev c 1 3
check "...or make a device node" [ ! -e "$D/dev" ]

echo "== 4. the network"
check "IPv6 is off inside the VM" [ "$(bx cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" = 1 ]
check "IPv4 internet works" [ "$(bx curl -sS -m 15 -o /dev/null -w '%{http_code}' https://example.com/)" = 200 ]
python3 -m http.server 18080 --bind 0.0.0.0 --directory "$W/empty" >/dev/null 2>&1 &
HPIDS+=($!)
sleep 1
ips=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
# shellcheck disable=SC2086 # one argument per address
res=$(bx sh -c 'for ip; do echo "$ip $(curl -s -m 3 -o /dev/null -w "%{http_code}" "http://$ip:18080/")"; done' sh $ips)
while read -r ip code; do
	check "this machine's address $ip is out of reach" [ "$code" = 000 ]
done <<<"$res"

echo "== 5. --port"
(bx --port 19090 timeout 20 python3 -m http.server 19090 --bind 127.0.0.1 --directory /tmp >/dev/null) &
bp=$!
code=000
for _ in $(seq 40); do
	code=$(curl -s -m 2 -o /dev/null -w '%{http_code}' http://127.0.0.1:19090/)
	[ "$code" = 200 ] && break
	sleep 1
done
check "localhost:19090 here reaches a server in the VM" [ "$code" = 200 ]
wait "$bp"
check "the forward is gone once the command ends" bash -c '[ "$(curl -s -m 2 -o /dev/null -w "%{http_code}" http://127.0.0.1:19090/)" = 000 ]'

echo "== 6. --reverse-port"
python3 -m http.server 19091 --bind 127.0.0.1 --directory "$W/empty" >/dev/null 2>&1 &
HPIDS+=($!)
sleep 1
code=$(bx --reverse-port 19091 curl -sS -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:19091/)
check "localhost:19091 in the VM reaches a server here" [ "$code" = 200 ]

echo "== 7. a port that's taken here"
bx --port 19091 true
rc=$?
check "refused, with a reason" bash -c '[ "$1" != 0 ] && grep -q "could not set up the port forwards" "$2"' _ "$rc" "$W/err"

echo "== 8. afterwards"
touch "$D/.verify-done"
wait "$keeper"
check "the VM is stopped" [ "$(incus query "/1.0/instances/$name" | jq -r .status)" = Stopped ]
check "no tunnel left behind" bash -c '! pgrep -f "[i]ncus exec $1 " >/dev/null' _ "$name"
check "the profile's card is isolated" bash -c 'for k in security.port_isolation security.ipv4_filtering security.ipv6_filtering; do [ "$(incus profile device get boxit eth0 "$k")" = true ] || exit 1; done'
if [ "$(id -u)" = "$(id -g)" ]; then want="both $(id -u) 1000"; else want=$(printf 'uid %s 1000\ngid %s 1000' "$(id -u)" "$(id -g)"); fi
check "the VM maps IDs on /work" [ "$(incus config get "$name" raw.idmap)" = "$want" ]
