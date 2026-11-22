#!/usr/bin/env bash
# Tests boxit against a fake incus (tests/bin/incus) that keeps its state in JSON files.
# usage: tests/run.sh [PATH-TO-BOXIT]    (default: the boxit next to this folder)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
BOXIT=$(realpath "${1:-$HERE/../boxit}")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/boxit-tests.XXXX")
trap 'rm -rf "$WORK"' EXIT
export PATH="$HERE/bin:$PATH" XDG_CONFIG_HOME="$WORK/cfg" XDG_RUNTIME_DIR="$WORK/run"
mkdir -p "$XDG_RUNTIME_DIR"
npass=0 nfail=0
ok() { echo "  ok   $*"; npass=$((npass + 1)); }
bad() { echo "  FAIL $*"; nfail=$((nfail + 1)); }
check() { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

fresh() {
	STUB_STATE=$(mktemp -d "$WORK/state.XXXX"); export STUB_STATE
	unset STUB_FAIL STUB_EXEC_RC
	PROJ=$(mktemp -d "$WORK/proj.XXXX")
}
bx() { (cd "$PROJ" && "$BOXIT" "$@") 2>"$STUB_STATE/err"; }
log() { cat "$STUB_STATE/log"; }
mark() { echo "--- mark" >>"$STUB_STATE/log"; }
since_mark() { tac "$STUB_STATE/log" | sed '/^--- mark/q' | tac; }  # from the last mark
export -f since_mark
vmfile() { ls "$STUB_STATE"/inst/boxit-proj-*.json 2>/dev/null | head -1; }
nrules() { jq '.egress | length' "$STUB_STATE/acl/boxit-egress.json"; }
# Every time a VM started or the user's command ran, the ACL had all 3 rules.
all_starts_safe() { ! log | grep -E '^(START|EXEC-RAN)' | grep -qv 'rules=3'; }
ran_cmd() { log | grep -q '^EXEC-RAN'; }
stopped_vm() { since_mark | grep -q '^incus stop boxit-proj'; }

echo "== T1 fresh run"
fresh; bx echo hi; rc=$?
check "exit 0" [ $rc = 0 ]
check "ACL has 3 rules" [ "$(nrules)" = 3 ]
check "profile references the ACL" grep -qE 'security.acls[:=] ?boxit-egress' "$STUB_STATE"/profile/boxit.yaml
check "VM records its folder" [ "$(jq -r '.config["user.boxit.path"]' "$(vmfile)")" = "$PROJ" ]
check "VM has /work mount of the folder" [ "$(jq -r '.devices.work.source' "$(vmfile)")" = "$PROJ" ]
check "command ran with ACL complete" all_starts_safe
check "command ran" ran_cmd
check "VM stopped afterwards" grep -q '^incus stop boxit-proj' "$STUB_STATE/log"

echo "== T2 second run is quiet and changes nothing"
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "no rule adds / creates / copies" bash -c '! sed -n "/^--- mark/,\$p" "$1" | grep -qE "rule add|profile create|acl create|^incus copy|device add"' _ "$STUB_STATE/log"
check "no messages except stopping" [ "$(grep -vc '^boxit: stopping' "$STUB_STATE/err")" = 0 ]

echo "== T3 rule add fails on first run, then a normal run"
fresh; STUB_FAIL=ruleadd:2 bx true; rc=$?
check "first run fails" [ $rc != 0 ]
check "no VM started by the failed run" bash -c '! grep -qE "^(START|EXEC-RAN)" "$1"' _ "$STUB_STATE/log"
bx true; rc=$?
check "second run exit 0" [ $rc = 0 ]
check "ACL repaired to 3 rules" [ "$(nrules)" = 3 ]
check "VM only ever started with ACL complete" all_starts_safe

echo "== T4 leftover from old script: empty ACL, profile + VM exist"
fresh; bx true >/dev/null
jq '.egress = []' "$STUB_STATE/acl/boxit-egress.json" >"$STUB_STATE/t" && mv "$STUB_STATE/t" "$STUB_STATE/acl/boxit-egress.json"
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "rules restored before start" bash -c 'sed -n "/^--- mark/,\$p" "$1" | grep -E "^(START|EXEC-RAN)" | grep -qv rules=3 && exit 1 || exit 0' _ "$STUB_STATE/log"
check "said it was repairing" grep -q 'missing the rule' "$STUB_STATE/err"

echo "== T5 disabled rule counts as missing; reordered destinations count as present"
fresh; bx true >/dev/null
jq '.egress[0].destination |= (split(",") | reverse | join(",")) | .egress[1].state = "disabled"' "$STUB_STATE/acl/boxit-egress.json" >"$STUB_STATE/t" && mv "$STUB_STATE/t" "$STUB_STATE/acl/boxit-egress.json"
mark; bx true
check "exactly one rule re-added (the disabled one)" [ "$(since_mark | grep -c 'rule add')" = 1 ]
check "...and it was the IPv6 rule" bash -c 'sed -n "/^--- mark/,\$p" "$1" | grep "rule add" | grep -q "destination=::/0"' _ "$STUB_STATE/log"

echo "== T6 /work device add fails during create, then a normal run"
fresh; STUB_FAIL=devadd:1 bx true; rc=$?
check "first run fails" [ $rc != 0 ]
bx true; rc=$?
check "second run exit 0" [ $rc = 0 ]
check "command ran with /work mounted" bash -c 'grep "^EXEC-RAN" "$1" | grep -q "work=$2:"' _ "$STUB_STATE/log" "$PROJ"

echo "== T7 VM with no folder recorded / someone else's folder"
fresh; bx true >/dev/null
f=$(vmfile); jq '.config = {}' "$f" >"$f.t" && mv "$f.t" "$f"
mark; bx true; rc=$?
check "refuses (no folder)" [ $rc != 0 ]
check "message suggests boxit --rm" grep -q 'no folder recorded.*boxit --rm' "$STUB_STATE/err"
jq '.config["user.boxit.path"] = "/elsewhere"' "$f" >"$f.t" && mv "$f.t" "$f"
bx true; rc=$?
check "refuses (other folder)" [ $rc != 0 ]
check "says who owns it" grep -q 'belongs to /elsewhere' "$STUB_STATE/err"
check "nothing ran" bash -c '! sed -n "/^--- mark/,\$p" "$1" | grep -q EXEC-RAN' _ "$STUB_STATE/log"

echo "== T8 stderr unwritable after the command (as with a closed terminal)"
fresh; bx true >/dev/null
mark
(cd "$PROJ" && STUB_EXEC_RC=7 "$BOXIT" true) 2>/dev/full; rc=$?
check "VM still stopped" stopped_vm
check "exit code is the command's (7)" [ $rc = 7 ]

# Network-card checks. vmdev NAME-OF-DEVICE JSON: give the VM its own device.
vmdev() { local f; f=$(vmfile); jq --arg d "$1" --argjson v "$2" '.devices[$d] = $v' "$f" >"$f.t" && mv "$f.t" "$f"; }
nothing_started() { ! since_mark | grep -qE '^(START|EXEC-RAN)'; }

echo "== T9 profile's eth0 loses the ACL"
fresh; bx true >/dev/null
sed -i '/security.acls: boxit-egress/d' "$STUB_STATE/profile/boxit.yaml"
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "names eth0" grep -q "aren't locked down (eth0)" "$STUB_STATE/err"
check "VM not started, command not run" nothing_started

echo "== T10 one VM gets an extra card eth1 without the ACL"
fresh; bx true >/dev/null
vmdev eth1 '{"type":"nic","network":"incusbr0","name":"eth1"}'
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "names eth1 only" grep -q "aren't locked down (eth1)" "$STUB_STATE/err"
check "VM not started, command not run" nothing_started

echo "== T11 VM's own eth0 replaces the profile's, without the ACL"
fresh; bx true >/dev/null
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0"}'
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "VM not started, command not run" nothing_started

echo "== T12 several ACLs on the card, with spaces, including ours: allowed"
fresh; bx true >/dev/null
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0","security.acls":"other-acl, boxit-egress","security.acls.default.egress.action":"reject","security.port_isolation":"true","security.ipv4_filtering":"true"}'
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "command ran" bash -c 'sed -n "/^--- mark/,\$p" "$1" | grep -q EXEC-RAN' _ "$STUB_STATE/log"

echo "== T13 VM already running when its card loses the ACL"
fresh; bx true >/dev/null
f=$(vmfile); jq '.status = "Running"' "$f" >"$f.t" && mv "$f.t" "$f"
vmdev eth1 '{"type":"nic","network":"incusbr0","name":"eth1"}'
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "command not run" bash -c '! sed -n "/^--- mark/,\$p" "$1" | grep -q EXEC-RAN' _ "$STUB_STATE/log"

echo "== T14 profile without the ACL exists before the very first run"
fresh
mkdir -p "$STUB_STATE/profile"
printf 'devices:\n  eth0:\n    type: nic\n    network: incusbr0\n    name: eth0\n' >"$STUB_STATE/profile/boxit.yaml"
bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "base VM created but never started" bash -c 'grep -q "^incus create .* boxit-base" "$1" && ! grep -qE "^incus start boxit-base|^START" "$1"' _ "$STUB_STATE/log"
check "names boxit-base" grep -q 'boxit-base has network cards that aren.t locked down' "$STUB_STATE/err"
sed -i 's/^    name: eth0$/    name: eth0\n    security.acls: boxit-egress\n    security.acls.default.egress.action: reject/' "$STUB_STATE/profile/boxit.yaml"
bx true; rc=$?
check "after fixing the profile: exit 0" [ $rc = 0 ]
check "base rebuilt from scratch (leftover deleted)" grep -q '^incus delete --force boxit-base' "$STUB_STATE/log"

echo "== T15 no network card at all: allowed (nothing to reach anything with)"
fresh; bx true >/dev/null
python3 -c 'import sys,yaml; p=sys.argv[1]; d=yaml.safe_load(open(p)); del d["devices"]["eth0"]; yaml.safe_dump(d, open(p,"w"))' "$STUB_STATE/profile/boxit.yaml"
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]

echo "== T16 fresh profile and VM cards reject unmatched traffic"
fresh; bx true >/dev/null
check "profile: default egress reject" grep -q 'security.acls.default.egress.action: reject' "$STUB_STATE/profile/boxit.yaml"
check "allow rule is the last rule added" bash -c 'grep "rule add" "$1" | tail -1 | grep -q "egress action=allow$"' _ "$STUB_STATE/log"

echo "== T17 first setup cut short right before the allow rule"
fresh; STUB_FAIL=ruleadd:3 bx true; rc=$?
check "first run fails" [ $rc != 0 ]
check "ACL left with the 2 rejects only (no allow)" [ "$(jq '[.egress[] | select(.action == "allow")] | length' "$STUB_STATE/acl/boxit-egress.json")" = 0 ]
check "no VM started" bash -c '! grep -qE "^(START|EXEC-RAN)" "$1"' _ "$STUB_STATE/log"
bx true; rc=$?
check "second run exit 0, ACL complete" [ $rc = 0 ] && [ "$(nrules)" = 3 ]

echo "== T18 upgrade from older boxit: no allow rule, profile allows unmatched traffic"
fresh; bx true >/dev/null
jq 'del(.egress[] | select(.action == "allow"))' "$STUB_STATE/acl/boxit-egress.json" >"$STUB_STATE/t" && mv "$STUB_STATE/t" "$STUB_STATE/acl/boxit-egress.json"
sed -i 's/default.egress.action: reject/default.egress.action: allow/' "$STUB_STATE/profile/boxit.yaml"
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "allow rule added" [ "$(nrules)" = 3 ]
check "profile switched to reject" grep -q 'security.acls.default.egress.action: reject' "$STUB_STATE/profile/boxit.yaml"
check "allow rule added before the profile switch, both before start" bash -c '
	l=$(sed -n "/^--- mark/,\$p" "$1")
	a=$(grep -n "action=allow" <<<"$l" | cut -d: -f1 | head -1); p=$(grep -n "profile device set" <<<"$l" | cut -d: -f1 | head -1); s=$(grep -n "^START" <<<"$l" | cut -d: -f1 | head -1)
	[ -n "$a" ] && [ -n "$p" ] && [ -n "$s" ] && [ "$a" -lt "$p" ] && [ "$p" -lt "$s" ]' _ "$STUB_STATE/log"
check "said so" grep -q 'setting security.acls.default.egress.action=reject on eth0 (was: allow)' "$STUB_STATE/err"
mark; bx true
check "third run: no changes" bash -c '! since_mark | grep -qE "rule add|profile device set"' 

echo "== T19 VM's own eth0 has the ACL but lets unmatched traffic out"
fresh; bx true >/dev/null
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0","security.acls":"boxit-egress","security.acls.default.egress.action":"allow"}'
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]
check "VM not started, command not run" nothing_started

echo "== T20 card has the ACL but no default egress action set"
fresh; bx true >/dev/null
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0","security.acls":"boxit-egress"}'
mark; bx true; rc=$?
check "refuses" [ $rc != 0 ]

echo "== T21 drop instead of reject is accepted (rule and card default)"
fresh; bx true >/dev/null
jq '.egress[0].action = "drop"' "$STUB_STATE/acl/boxit-egress.json" >"$STUB_STATE/t" && mv "$STUB_STATE/t" "$STUB_STATE/acl/boxit-egress.json"
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0","security.acls":"boxit-egress","security.acls.default.egress.action":"drop","security.port_isolation":"true","security.ipv4_filtering":"true"}'
mark; bx true; rc=$?
check "exit 0, no rule re-added" [ $rc = 0 ] && ! since_mark | grep -q 'rule add'

# ---- IPv6 blocked (issue 3) --------------------------------------------------------
rule_adds() { since_mark | grep 'network acl rule add'; }

echo "== T22 fresh ACL: IPv4 private ranges, all IPv6, then allow (last)"
fresh; mark; bx true >/dev/null
check "3 rule adds" [ "$(rule_adds | wc -l)" = 3 ]
check "1st: IPv4 private ranges only" bash -c 'grep "rule add" "$1" | sed -n 1p | grep -q "destination=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10$"' _ "$STUB_STATE/log"
check "2nd: all IPv6" bash -c 'grep "rule add" "$1" | sed -n 2p | grep -q "action=reject destination=::/0$"' _ "$STUB_STATE/log"
check "3rd: allow" bash -c 'grep "rule add" "$1" | sed -n 3p | grep -q "egress action=allow$"' _ "$STUB_STATE/log"

echo "== T23 upgrade from the previous ACL (fc00::/7 + fe80 rules + allow)"
fresh; bx true >/dev/null
jq '.egress = [
	{action:"reject",destination:"10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,169.254.0.0/16,100.64.0.0/10,fc00::/7",state:"enabled"},
	{action:"reject",destination:"fe80::/10",protocol:"tcp",state:"enabled"},
	{action:"reject",destination:"fe80::/10",protocol:"udp",state:"enabled"},
	{action:"allow",state:"enabled"}]' "$STUB_STATE/acl/boxit-egress.json" >"$STUB_STATE/t" && mv "$STUB_STATE/t" "$STUB_STATE/acl/boxit-egress.json"
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "adds the 2 new rules (IPv4 list, ::/0), keeps the old ones" [ "$(rule_adds | wc -l)" = 2 ] && [ "$(nrules)" = 6 ]
check "VM started only after both were in" bash -c 'tac "$1" | sed "/^--- mark/q" | grep "^START" | grep -q "rules=6"' _ "$STUB_STATE/log"
mark; bx true
check "next run: no changes" [ "$(rule_adds | wc -l)" = 0 ]

echo "== T24 IPv6 turned off inside the VM after each boot"
fresh; bx true
check "sysctl run as root after start, before the command" bash -c '
	l=$(cat "$1"); s=$(grep -n "^START" <<<"$l" | head -1 | cut -d: -f1)
	c=$(grep -n "^EXEC-ROOT: sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1" <<<"$l" | head -1 | cut -d: -f1)
	e=$(grep -n "^EXEC-RAN" <<<"$l" | head -1 | cut -d: -f1)
	[ -n "$s" ] && [ -n "$c" ] && [ -n "$e" ] && [ "$s" -lt "$c" ] && [ "$c" -lt "$e" ]' _ "$STUB_STATE/log"
f=$(vmfile); jq '.status = "Running"' "$f" >"$f.t" && mv "$f.t" "$f"
mark; bx true
check "not repeated when the VM was already running" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q sysctl' _ "$STUB_STATE/log"

# ---- port forwarding --------------------------------------------------------------
ssh_line() { grep '^SSH \[-F\]' "$STUB_STATE/log" | tail -1; }
has_arg() { ssh_line | grep -qF -- "$1"; }

echo "== T25 port specs that are accepted"
fresh
bx --port 9090 --port=7000 --port 8080:127.0.0.1:3000 --reverse-port 5432 --reverse-port=6000:db.lan:5432 true; rc=$?
check "exit 0" [ $rc = 0 ]
check "--port 9090 -> -L 127.0.0.1:9090:localhost:9090" has_arg '[-L] [127.0.0.1:9090:localhost:9090]'
check "--port=7000" has_arg '[-L] [127.0.0.1:7000:localhost:7000]'
check "--port 8080:127.0.0.1:3000" has_arg '[-L] [127.0.0.1:8080:127.0.0.1:3000]'
check "--reverse-port 5432 -> -R 127.0.0.1:5432:localhost:5432" has_arg '[-R] [127.0.0.1:5432:localhost:5432]'
check "--reverse-port=6000:db.lan:5432" has_arg '[-R] [127.0.0.1:6000:db.lan:5432]'
check "says what is forwarded" grep -q 'forwarding localhost:9090 here -> localhost:9090 in the VM' "$STUB_STATE/err"
check "...both ways" grep -q 'forwarding localhost:5432 in the VM -> localhost:5432 here' "$STUB_STATE/err"

echo "== T26 port specs that are refused (nothing happens)"
for spec in 0 70000 abc 1:2 9090:host: 9090::9090 09090 1:2:3:4 9090:bad_host:1 "9090 :x:1"; do
	fresh; bx --port "$spec" true; rc=$?
	check "--port '$spec' refused" bash -c '[ "$1" = 1 ] && grep -q "bad --port" "$2" && [ ! -s "$3" ]' _ "$rc" "$STUB_STATE/err" "$STUB_STATE/log"
done
fresh; bx --reverse-port abc true; rc=$?
check "--reverse-port abc refused" bash -c '[ "$1" = 1 ] && grep -q "bad --reverse-port" "$2"' _ "$rc" "$STUB_STATE/err"
fresh; bx --port; rc=$?
check "--port with no value refused" bash -c '[ "$1" = 1 ] && grep -q "needs a port" "$2"' _ "$rc" "$STUB_STATE/err"
fresh; bx --port 1 --list; rc=$?
check "--list after --port: usage, exit 2" [ $rc = 2 ]
fresh; bx -- --port; rc=$?
check "-- --port runs a command named --port" bash -c 'grep -q "^EXEC-RAN.*: bash -lc exec \"\$@\" boxit --port$" "$1"' _ "$STUB_STATE/log"

echo "== T27 the tunnel: how it is opened and closed"
fresh; bx --port 9090 true; rc=$?
check "exit 0" [ $rc = 0 ]
for a in '[-F] [/dev/null]' '[-M]' '[-f]' '[-N]' '[ExitOnForwardFailure=yes]' '[BatchMode=yes]' '[IdentityAgent=none]' '[IdentitiesOnly=yes]' '[StrictHostKeyChecking=no]' '[UserKnownHostsFile=/dev/null]'; do
	check "ssh gets $a" has_arg "$a"
done
check "ProxyCommand runs sshd -i in this VM over incus exec" bash -c 'grep "^SSH \[-F\]" "$1" | grep -qE "\[ProxyCommand=incus exec boxit-proj-[a-z0-9-]+ -T -- sh -c .mkdir -p /run/sshd && exec /usr/sbin/sshd -i "' _ "$STUB_STATE/log"
check "sshd only allows agent, keys, tcp forwarding, loopback" bash -c 'l=$(grep "^SSH \[-F\]" "$1"); for o in AllowUsers=agent PasswordAuthentication=no AllowTcpForwarding=yes GatewayPorts=no PermitTTY=no AllowAgentForwarding=no X11Forwarding=no; do grep -q -- "-o $o" <<<"$l" || exit 1; done' _ "$STUB_STATE/log"
check "key made once, public part pushed as root" bash -c '[ -f "$1/boxit/ssh_key" ] && grep -q "file push -p --uid 0 --gid 0 --mode 0644 $1/boxit/ssh_key.pub boxit-proj-.*/etc/boxit/authorized_keys" "$2"' _ "$XDG_CONFIG_HOME" "$STUB_STATE/log"
check "order: tunnel up, command, tunnel closed, VM stopped" bash -c '
	l=$(cat "$1"); o=$(grep -n "^SSH-OPEN" <<<"$l" | cut -d: -f1); e=$(grep -n "^EXEC-RAN" <<<"$l" | cut -d: -f1)
	x=$(grep -n "^SSH-EXIT" <<<"$l" | cut -d: -f1); s=$(grep -n "^incus stop boxit-proj" <<<"$l" | tail -1 | cut -d: -f1)
	[ -n "$o" ] && [ -n "$e" ] && [ -n "$x" ] && [ -n "$s" ] && [ "$o" -lt "$e" ] && [ "$e" -lt "$x" ] && [ "$x" -lt "$s" ]' _ "$STUB_STATE/log"
check "tunnel's socket folder removed" bash -c '! ls -d "$1"/boxit.* >/dev/null 2>&1' _ "$XDG_RUNTIME_DIR"
fresh; bx true
check "no port flags: no ssh at all" bash -c '! grep -q "^SSH" "$1"' _ "$STUB_STATE/log"

echo "== T28 tunnel and failures"
fresh; bx true >/dev/null
mark; STUB_EXEC_RC=3 bx --port 9090 false; rc=$?
check "failing command: its exit code (3)" [ $rc = 3 ]
check "...tunnel still closed" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^SSH-EXIT"' _ "$STUB_STATE/log"
mark; STUB_SSH_FAIL=1 bx --port 9090 true; rc=$?
check "forward fails (port in use): refused" [ $rc != 0 ]
check "...says why" grep -q 'could not set up the port forwards' "$STUB_STATE/err"
check "...command not run" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "^EXEC-RAN"' _ "$STUB_STATE/log"
check "...VM stopped again" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop boxit-proj"' _ "$STUB_STATE/log"
mark
(cd "$PROJ" && STUB_EXEC_RC=7 "$BOXIT" --port 9090 true) 2>/dev/full; rc=$?
check "stderr unwritable: tunnel closed" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^SSH-EXIT"' _ "$STUB_STATE/log"
check "...VM stopped, exit code 7" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop boxit-proj" && [ "$2" = 7 ]' _ "$STUB_STATE/log" "$rc"

echo "== T29 VM from an older base without sshd"
fresh; bx true >/dev/null
rm -f "$STUB_STATE"/inst/boxit-proj-*.sshd
mark; bx --port 9090 true; rc=$?
check "exit 0" [ $rc = 0 ]
check "installs openssh-server first, says so" bash -c 'grep -q "installing openssh-server" "$2" && tac "$1" | sed "/^--- mark/q" | tac | grep -E "^(incus exec boxit-proj-[a-z0-9-]+ -- bash -s|SSH-OPEN)" | head -1 | grep -q "bash -s"' _ "$STUB_STATE/log" "$STUB_STATE/err"
mark; bx --port 9090 true
check "next run: no install" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q -- "-- bash -s"' _ "$STUB_STATE/log"

# ---- cleanup on any exit after the VM may be running -------------------------------
echo "== T30 a failure after start still stops the VM"
fresh; bx true >/dev/null
mkdir -p "$XDG_CONFIG_HOME/boxit" && echo tok >"$XDG_CONFIG_HOME/boxit/claude-oauth-token"
mark; STUB_FAIL=push:1 bx true; rc=$?
rm -f "$XDG_CONFIG_HOME/boxit/claude-oauth-token"
check "token push fails: refused" [ $rc != 0 ]
check "...VM stopped (it was left running before)" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop boxit-proj"' _ "$STUB_STATE/log"
fresh; bx true >/dev/null
sed -i '/security.acls: boxit-egress/d' "$STUB_STATE/profile/boxit.yaml"
mark; bx true
check "refused before start: no stop attempted" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop"' _ "$STUB_STATE/log"

# ---- isolation on the bridge (issue 5) ---------------------------------------------
setjson() { local f=$1; shift; jq "$@" "$f" >"$f.t" && mv "$f.t" "$f"; }

echo "== T31 profile cards are isolated; an older profile is upgraded once"
fresh; bx true >/dev/null
for k in port_isolation ipv4_filtering ipv6_filtering; do
	check "new profile: security.$k true" grep -q "security.$k: \"true\"" "$STUB_STATE/profile/boxit.yaml"
done
cat >"$STUB_STATE/profile/boxit.yaml" <<'YAML'
config:
  limits.cpu: "4"
  limits.memory: 8GiB
devices:
  eth0:
    name: eth0
    network: incusbr0
    security.acls: boxit-egress
    security.acls.default.egress.action: reject
    security.acls.default.ingress.action: reject
    type: nic
  root:
    path: /
    pool: default
    size: 20GiB
    type: disk
YAML
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "sets the 3 isolation keys, not the egress one" bash -c 'l=$(tac "$1" | sed "/^--- mark/q"); [ "$(grep -c "profile device set" <<<"$l")" = 3 ] && ! grep -q "egress.action" <<<"$(grep "profile device set" <<<"$l")"' _ "$STUB_STATE/log"
check "says so" grep -q 'setting security.port_isolation=true on eth0 (was: unset)' "$STUB_STATE/err"
mark; bx true
check "next run: no changes" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "profile device set"' _ "$STUB_STATE/log"

echo "== T32 a card without isolation or filtering is refused"
for missing in security.port_isolation security.ipv4_filtering; do
	fresh; bx true >/dev/null
	vmdev eth0 "$(jq -nc --arg m "$missing" '{type:"nic",network:"incusbr0",name:"eth0","security.acls":"boxit-egress","security.acls.default.egress.action":"reject","security.port_isolation":"true","security.ipv4_filtering":"true"} | del(.[$m])')"
	mark; bx true; rc=$?
	check "without $missing: refused, nothing run" bash -c '[ "$1" != 0 ] && ! tac "$2" | sed "/^--- mark/q" | grep -qE "^(START|EXEC-RAN)"' _ "$rc" "$STUB_STATE/log"
done
fresh; bx true >/dev/null
vmdev eth0 '{"type":"nic","network":"incusbr0","name":"eth0","security.acls":"boxit-egress","security.acls.default.egress.action":"reject","security.port_isolation":"yes","security.ipv4_filtering":"1"}'
mark; bx true; rc=$?
check "yes / 1 count as true" [ $rc = 0 ]

echo "== T33 the bridge's subnet must be inside a rejected range"
for net in 10.106.146.1/24 192.168.5.1/24 172.31.0.1/16 100.100.0.1/16 none ""; do
	fresh; STUB_BRIDGE_V4=$net bx true; rc=$?
	check "'$net' accepted" [ $rc = 0 ]
done
for net in 172.32.0.1/16 203.0.113.1/24 10.0.0.1/7 100.128.0.1/16 auto; do
	fresh; STUB_BRIDGE_V4=$net bx true; rc=$?
	check "'$net' refused before anything is set up" bash -c '[ "$1" != 0 ] && grep -q "isn.t inside a range the ACL rejects" "$2" && ! grep -qE "^incus (copy|create|start)" "$3"' _ "$rc" "$STUB_STATE/err" "$STUB_STATE/log"
done

# ---- ID mapping on /work (issue 4) -------------------------------------------------
echo "== T34 a new VM maps IDs on its folder share"
fresh; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "copy sets raw.idmap to your uid" bash -c 'grep -q "^incus copy boxit-base/ready boxit-proj-[a-z0-9-]* -c user.boxit.path=.* -c raw.idmap=both $2 1000$" "$1"' _ "$STUB_STATE/log" "$(id -u)"
check "VM has it" [ "$(jq -r '.config["raw.idmap"]' "$(vmfile)")" = "both $(id -u) 1000" ]
check "/work is virtiofs (io.bus)" [ "$(jq -r '.devices.work["io.bus"]' "$(vmfile)")" = virtiofs ]
check "no mapping message for a new VM" bash -c '! grep -q "mapping IDs" "$1"' _ "$STUB_STATE/err"

echo "== T35 uid and gid differ"
fresh; STUB_UID=1001 STUB_GID=1002 bx true; rc=$?
check "raw.idmap has separate uid and gid lines" [ "$(jq -r '.config["raw.idmap"]' "$(vmfile)")" = $'uid 1001 1000\ngid 1002 1000' ]
mark; STUB_UID=1001 STUB_GID=1002 bx true
check "next run: no change" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "config set"' _ "$STUB_STATE/log"

echo "== T36 a VM made by an older boxit (no mapping)"
fresh; bx true >/dev/null
f=$(vmfile); setjson "$f" 'del(.config["raw.idmap"]) | del(.devices.work["io.bus"])'
mark; bx true; rc=$?
check "stopped: mapping added, exit 0" bash -c '[ "$1" = 0 ] && [ "$(jq -r ".config[\"raw.idmap\"]" "$2")" = "both $3 1000" ] && [ "$(jq -r ".devices.work[\"io.bus\"]" "$2")" = virtiofs ]' _ "$rc" "$f" "$(id -u)"
check "...before it started" bash -c 'l=$(tac "$1" | sed "/^--- mark/q" | tac); c=$(grep -n "config set .* raw.idmap=" <<<"$l" | cut -d: -f1); s=$(grep -n "^START" <<<"$l" | cut -d: -f1); [ -n "$c" ] && [ -n "$s" ] && [ "$c" -lt "$s" ]' _ "$STUB_STATE/log"
check "...and said so" grep -q 'mapping IDs on /work' "$STUB_STATE/err"
check "...no warning about files (all yours)" bash -c '! grep -q "files that aren.t yours" "$1"' _ "$STUB_STATE/err"
mark; bx true
check "next run: no change" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -qE "config (set|device set)"' _ "$STUB_STATE/log"
setjson "$f" 'del(.config["raw.idmap"]) | .status = "Running"'
mark; bx true; rc=$?
check "running without mapping: refused" bash -c '[ "$1" != 0 ] && grep -q "running without ID mapping" "$2"' _ "$rc" "$STUB_STATE/err"
check "...nothing run, config untouched" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -qE "^EXEC-RAN|config set"' _ "$STUB_STATE/log"

echo "== T37 when mapping is turned on, files that aren't yours are pointed out"
fresh; bx true >/dev/null
touch "$PROJ/somefile"
setjson "$(vmfile)" 'del(.config["raw.idmap"])'
STUB_UID=4242 STUB_GID=4242 bx true; rc=$?
check "warns, names a file and how to list them" bash -c 'grep -q "files that aren.t yours (e.g. $2/somefile)" "$1" && grep -q "find .$2. -xdev" "$1"' _ "$STUB_STATE/err" "$PROJ"

echo "== T38 a VM with the old 6.8 kernel gets a note on boot"
fresh; STUB_KERNEL=6.8.0-149-generic bx true; rc=$?
check "exit 0, note with both fixes" bash -c '[ "$1" = 0 ] && grep -q "runs kernel 6.8.0-149-generic" "$2" && grep -q "linux-generic-hwe-24.04" "$2" && grep -q "boxit --rm boxit-base" "$2"' _ "$rc" "$STUB_STATE/err"
fresh; bx true
check "6.14: no note" bash -c '! grep -q "runs kernel" "$1"' _ "$STUB_STATE/err"
f=$(vmfile); setjson "$f" '.status = "Running"'
mark; STUB_KERNEL=6.8.0-149-generic bx true
check "already running: not checked again" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "uname"' _ "$STUB_STATE/log"
check "base provisioning installs the HWE kernel" grep -q 'apt-get install -y -q linux-generic-hwe-24.04' "$BOXIT"

# ---- stdout and concurrent sessions ------------------------------------------------
echo "== T39 stdout carries only the command's output"
fresh
out=$(cd "$PROJ" && STUB_EXEC_OUT=hello "$BOXIT" true 2>"$STUB_STATE/err")
check "first run (builds the base): just the command's output" [ "$out" = hello ]
check "...setup output went to stderr instead" grep -q 'Network ACL boxit-egress created' "$STUB_STATE/err"
rm -f "$STUB_STATE"/inst/boxit-proj-*.sshd
out=$(cd "$PROJ" && STUB_EXEC_OUT=hello "$BOXIT" --port 9090 true 2>/dev/null)
check "with --port and a one-time sshd install: just the output" [ "$out" = hello ]

lockfile() { echo "$XDG_RUNTIME_DIR/boxit-locks/$(basename "$(vmfile)" .json).lock"; }

echo "== T40 another boxit session in the VM: it is not stopped"
fresh; bx true >/dev/null
check "lock file per VM in the runtime dir" [ -f "$(lockfile)" ]
flock -s "$(lockfile)" sleep 3 &
holder=$!
sleep 0.3
mark; bx true; rc=$?
check "exit 0" [ $rc = 0 ]
check "VM left running for the other session" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop"' _ "$STUB_STATE/log"
wait "$holder"
mark; bx true
check "once it's gone, the VM is stopped again" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^incus stop boxit-proj"' _ "$STUB_STATE/log"

echo "== T41 a session that starts while the VM is being stopped waits for it"
fresh; bx true >/dev/null
flock -x "$(lockfile)" sleep 1.5 &
holder=$!
sleep 0.3
mark; bx true; rc=$?
wait "$holder"
check "exit 0" [ $rc = 0 ]
check "says it's waiting" grep -q 'waiting for boxit-proj-.* to finish stopping' "$STUB_STATE/err"
check "...then starts the VM and runs the command" bash -c 'tac "$1" | sed "/^--- mark/q" | grep -q "^EXEC-RAN"' _ "$STUB_STATE/log"

echo "== T42 a VM another session has only just started: wait for its agent too"
fresh; bx true >/dev/null
setjson "$(vmfile)" '.status = "Running"'
mark; bx true
check "agent probed before anything else runs in it" bash -c 'l=$(tac "$1" | sed "/^--- mark/q" | tac); p=$(grep -n "^incus exec boxit-proj-[a-z0-9-]* -- true" <<<"$l" | head -1 | cut -d: -f1); e=$(grep -n "^EXEC-RAN" <<<"$l" | head -1 | cut -d: -f1); [ -n "$p" ] && [ -n "$e" ] && [ "$p" -lt "$e" ]' _ "$STUB_STATE/log"
check "...but not booted again (no sysctl)" bash -c '! tac "$1" | sed "/^--- mark/q" | grep -q sysctl' _ "$STUB_STATE/log"

echo
echo "passed $npass, failed $nfail"
[ $nfail = 0 ]
