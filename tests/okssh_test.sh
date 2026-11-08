#!/bin/sh
# Regression tests for okssh — POSIX sh, no network, throwaway HOME.
#
#   sh tests/okssh_test.sh                 # runs ./okssh with sh
#   OKSSH_SH=dash sh tests/okssh_test.sh   # pick the interpreter okssh runs under
#
# Every test builds its own fake ~/.ssh/config + ~/.config/okssh and checks
# the files okssh leaves behind (and its plain, colour-free output).

# shellcheck disable=SC2034  # out/rc/esc are read inside the eval'd check "…" strings
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
OKSSH="$HERE/okssh"
OKSSH_SH="${OKSSH_SH:-sh}"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/okssh-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
PASS=0; FAIL=0; CUR=""

# ── harness ───────────────────────────────────────────────────────────────────

begin() {
    CUR="$1"
    H="$ROOT/$(printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_')"
    mkdir -p "$H/.ssh" "$H/.config/okssh"; chmod 700 "$H/.ssh"
    CFG="$H/.ssh/config"; PREFS="$H/.config/okssh/preferences"
    : > "$PREFS"
}
# okssh with the test HOME, CLI mode, stdin from the caller (default /dev/null)
ok() { HOME="$H" HAS_WHIPTAIL=0 "$OKSSH_SH" "$OKSSH" "$@"; }
pass() { PASS=$((PASS + 1)); }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL [%s] %s\n' "$CUR" "$1"; }
check() { if eval "$1"; then pass; else fail "$2"; fi; }
has()   { grep -qF -- "$2" "$1"; }   # file contains literal text
keygen() { ssh-keygen -q -t ed25519 -N "" -C test -f "$1"; }

# A block with everything okssh's rebuild-from-fields code used to lose
std_config() {
    keygen "$H/.ssh/id_ed25519_web"
    cat > "$CFG" <<EOF
Host web
    # Note: DB: primary replica
    # Group: prod
    HostName 192.0.2.10
    User deploy
    Port 22
    IdentityFile $H/.ssh/id_ed25519_web
    IdentitiesOnly yes
    LocalForward 5432 localhost:5432
    LocalForward 6379 localhost:6379
    RemoteForward 9000 localhost:9000
    SetEnv TERM=xterm-256color

Host app
    HostName 192.0.2.20
    ProxyJump web
    # JumpAlias: web

Host db
    HostName 192.0.2.30
    ProxyJump bastion,web
EOF
}
ssh_parses() { ssh -G -F "$CFG" "$1" >/dev/null 2>&1; }

# ── tests ─────────────────────────────────────────────────────────────────────

begin "rename keeps the block and updates every reference"
std_config
printf 'audit_threshold_web=30\nbootstrap_web=2026-07-01\nlast_connect_web=2026-07-02 10:00\npinned_aliases=app,web\n' > "$PREFS"
printf '\n[tunnel]\nname=pg\nalias=web\nforward=5432:localhost:5432\ntype=local\n\n' > "$H/.config/okssh/tunnels"
ok rename web web2 </dev/null >/dev/null 2>&1
check 'has "$CFG" "Host web2"'                               "Host line renamed"
check '! grep -qx "Host web" "$CFG"'                         "old Host line gone"
check 'has "$CFG" "# Note: DB: primary replica"'             "note with ': ' kept whole"
check 'has "$CFG" "LocalForward 5432 localhost:5432"'        "multi-word LocalForward intact"
check 'has "$CFG" "LocalForward 6379 localhost:6379"'        "second LocalForward kept"
check 'has "$CFG" "RemoteForward 9000 localhost:9000"'       "RemoteForward kept"
check 'has "$CFG" "SetEnv TERM=xterm-256color"'              "SetEnv kept"
check 'has "$CFG" "IdentityFile $H/.ssh/id_ed25519_web2"'    "IdentityFile follows key rename"
check '[ -f "$H/.ssh/id_ed25519_web2" ]'                     "key file renamed"
check 'has "$CFG" "ProxyJump web2"'                          "other alias ProxyJump updated"
check 'has "$CFG" "# JumpAlias: web2"'                       "JumpAlias comment updated"
check 'has "$CFG" "ProxyJump bastion,web2"'                  "jump chain hop updated"
check 'has "$PREFS" "audit_threshold_web2=30"'               "audit threshold migrated"
check 'has "$PREFS" "bootstrap_web2=2026-07-01"'             "bootstrap pref migrated"
check '! grep -q "^audit_threshold_web=" "$PREFS"'           "old pref removed"
check 'has "$PREFS" "pinned_aliases=app,web2"'               "pin list updated"
check 'has "$H/.config/okssh/tunnels" "alias=web2"'          "tunnel alias updated"
check 'ssh_parses app'                                       "ssh still parses the config"
check '[ "$(awk "/^Host /{print \$2}" "$CFG" | tr "\n" " ")" = "web2 app db " ]' "block keeps its position"

begin "tag and untag only touch the Group comment"
std_config
cp "$CFG" "$H/before"
ok tag web lab </dev/null >/dev/null 2>&1
check 'has "$CFG" "# Group: prod,lab"'                       "group added"
ok untag web prod </dev/null >/dev/null 2>&1
check 'has "$CFG" "# Group: lab"'                            "group removed"
check '[ "$(grep -v "# Group:" "$CFG")" = "$(grep -v "# Group:" "$H/before")" ]' "nothing else changed"
ok tag app newgrp </dev/null >/dev/null 2>&1
check '[ "$(sed -n "/^Host app/{n;p;}" "$CFG")" = "    # Group: newgrp" ]' "new comment goes right after Host"
check 'ssh_parses web'                                       "ssh still parses the config"

begin "edit with all-blank answers changes nothing"
std_config
cp "$CFG" "$H/before"
printf '\n\n\n\n\n\n\n\n\n\n' | ok edit web >/dev/null 2>&1
check 'cmp -s "$CFG" "$H/before"'                            "config byte-identical"

begin "edit updates only the edited field, in place"
std_config
printf 'new note\n\n\n\n\n\n\n\n\n\n' | ok edit web >/dev/null 2>&1
check 'has "$CFG" "# Note: new note"'                        "note updated"
check '[ "$(grep -c "Note:" "$CFG")" = 1 ]'                  "no duplicate note"
check 'has "$CFG" "LocalForward 5432 localhost:5432"'        "LocalForward intact"
check 'has "$CFG" "RemoteForward 9000 localhost:9000"'       "custom option intact"

begin "typed answers don't kill CLI wizards (cli_prompt exit status)"
std_config
printf 'n2\nlab\n192.0.2.11\n2222\nroot\n\n\n\n\n' | ok edit web >/dev/null 2>&1; rc=$?
check '[ "$rc" = 0 ]'                                         "edit exits 0 after typed answers"
check 'has "$CFG" "# Note: n2" && has "$CFG" "# Group: lab" && has "$CFG" "HostName 192.0.2.11"' "typed values written"
check 'has "$CFG" "Port 2222" && has "$CFG" "User root"'     "port/user written"
printf 'my-snip\nshow uptime\nuptime -p\n\n' | ok snip add >/dev/null 2>&1; rc=$?
check '[ "$rc" = 0 ] && has "$H/.config/okssh/snippets" "[my-snip]"' "snip add with typed name works"
check 'has "$H/.config/okssh/snippets" "command=uptime -p"'  "snippet command stored"
printf '\n\ny\n' | ok snip edit my-snip >/dev/null 2>&1
check 'has "$H/.config/okssh/snippets" "use_sudo=yes"'       "snip edit sets sudo"
printf '\n\n\n' | ok snip edit my-snip >/dev/null 2>&1
check 'has "$H/.config/okssh/snippets" "use_sudo=yes"'       "Enter keeps sudo on (default = current)"

begin "tunnel add with no args runs a wizard"
std_config
printf 'pg\nweb\nlocal\n5432:localhost:5432\n' | ok tunnel add >/dev/null 2>&1
check 'has "$H/.config/okssh/tunnels" "name=pg" && has "$H/.config/okssh/tunnels" "forward=5432:localhost:5432"' "tunnel saved"
ok tunnel add "bad/name" web 1:a:1 </dev/null >/dev/null 2>&1; rc=$?
check '[ "$rc" != 0 ]'                                        "unsafe tunnel name rejected"

begin "snip push (no args) survives a non-bootstrapped last alias"
std_config
printf 'bootstrap_web=2026-07-01\n' > "$PREFS"           # db (last) is not bootstrapped
printf '[s]\ndescription=\ncommand=true\nuse_sudo=no\ncreated=x\n\n' > "$H/.config/okssh/snippets"
out=$(ok snip push </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q "Pushing to web"'          "gets as far as pushing to web"

begin "clone copies the whole block with a fresh key"
std_config
printf '\n\n\n\n\n\n\n' | ok clone web web3 >/dev/null 2>&1
check 'has "$CFG" "Host web3"'                               "clone created"
check '[ "$(grep -c "RemoteForward 9000" "$CFG")" = 2 ]'     "options copied"
check 'has "$CFG" "IdentityFile $H/.ssh/id_ed25519_web3"'    "new key referenced"
check '[ -f "$H/.ssh/id_ed25519_web3" ]'                     "new key generated"
check 'has "$CFG" "IdentityFile $H/.ssh/id_ed25519_web"'     "source keeps its key"

begin "one backup per command, holding the pre-change state"
std_config
ok tag web lab </dev/null >/dev/null 2>&1
n=$(ls "$H/.config/okssh/backups" | wc -l | tr -d ' ')
check '[ "$n" = 1 ]'                                          "exactly one backup (got $n)"
check 'grep -qx "Host web" "$H/.config/okssh/backups"/config.*' "backup still contains the alias"
check '! grep -q "lab" "$H/.config/okssh/backups"/config.*'  "backup is the state before the change"
ok untag web lab </dev/null >/dev/null 2>&1
n=$(ls "$H/.config/okssh/backups" | wc -l | tr -d ' ')
check '[ "$n" = 2 ]'                                          "same-second backups don't overwrite (got $n)"

begin "rm --yes forgets per-alias prefs and the pin"
std_config
printf 'sshpass_web=c2VjcmV0MQ==\nwol_mac_web=aa:bb:cc:dd:ee:ff\npinned_aliases=web,app\nlast_connect_webx=keep\n' > "$PREFS"
printf '\n[tunnel]\nname=pg\nalias=web\nforward=5432:localhost:5432\ntype=local\n\n' > "$H/.config/okssh/tunnels"
out=$(ok rm web --yes 2>&1 </dev/null)
check '! grep -qx "Host web" "$CFG"'                         "block removed"
check '! grep -q "^sshpass_web=" "$PREFS"'                   "stored password removed"
check '! grep -q "^wol_mac_web=" "$PREFS"'                   "wol pref removed"
check 'has "$PREFS" "pinned_aliases=app"'                    "unpinned"
check 'has "$PREFS" "last_connect_webx=keep"'                "similar-named pref untouched"
check 'printf "%s" "$out" | grep -q "tunnel(s) still pointing at web: pg"' "warns about tunnels"

begin "prefs: values with '=' and exact keys"
printf 'sync_path=/data/a=b\npinned_aliases=x\n' > "$PREFS"
cat > "$CFG" <<'EOF'
Host x
    HostName 192.0.2.1
EOF
ok pin x </dev/null >/dev/null 2>&1          # read-only path: must not mangle
check 'has "$PREFS" "sync_path=/data/a=b"'                    "'=' in value preserved"
ok prefer key_type rsa </dev/null >/dev/null 2>&1
check 'has "$PREFS" "key_type=rsa"'                           "pref_set appends"
ok prefer key_type ecdsa </dev/null >/dev/null 2>&1
check '[ "$(grep -c "^key_type=" "$PREFS")" = 1 ] && has "$PREFS" "key_type=ecdsa"' "pref_set replaces in place"
check '[ "$(stat -c %a "$PREFS" 2>/dev/null || stat -f %Lp "$PREFS")" = 600 ]' "prefs stay mode 600"

begin "export: stdout, portable format, Ansible inventory"
std_config
ok export - </dev/null > "$H/exp" 2>/dev/null
check 'has "$H/exp" "localfwd=5432 localhost:5432"'          "full LocalForward exported"
check 'has "$H/exp" "note=DB: primary replica"'              "full note exported"
check '! [ -e "$H/-" ]'                                        "no file named '-'"
ok export --ansible - </dev/null > "$H/inv" 2>/dev/null
check 'has "$H/inv" "[all]"'                                   "inventory has [all]"
check 'grep -q "^web ansible_host=192.0.2.10 ansible_user=deploy ansible_port=22" "$H/inv"' "host vars"
check 'grep -q "^app .*ProxyJump=web" "$H/inv"'              "jump becomes ssh args"
check '[ "$(sed -n "/^\[prod\]/{n;p;}" "$H/inv")" = "web" ]' "group section"
check '! ls "$H" | grep -q -- "--ansible"'                    "no file named --ansible"

begin "diff: identical vs changed"
std_config
mkdir -p "$H/sync"; printf 'sync_path=%s/sync\n' "$H" > "$PREFS"
ok tag web lab </dev/null >/dev/null 2>&1         # writes the sync export
out=$(ok diff </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q "no differences"'        "match reported"
printf '\nHost new1\n    HostName 192.0.2.99\n' >> "$CFG"
out=$(ok diff </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q "+name=new1"'            "added alias shown"

begin "colours only on a terminal"
std_config
out=$(ok ls </dev/null 2>&1)
esc=$(printf '\033')
check '! printf "%s" "$out" | grep -q "$esc"'                "no ANSI when captured"
out=$(CLICOLOR_FORCE=1 ok ls </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q "$esc"'                  "CLICOLOR_FORCE=1 forces colour"
out=$(CLICOLOR_FORCE=1 NO_COLOR=1 ok ls </dev/null 2>&1)
check '! printf "%s" "$out" | grep -q "$esc"'                "NO_COLOR wins"

begin "ls: hidden, pinned order, full fields"
std_config
printf '\nHost secret\n    # Group: hidden\n    HostName 192.0.2.40\n' >> "$CFG"
printf 'pinned_aliases=db\n' > "$PREFS"
out=$(ok ls </dev/null 2>&1)
check '! printf "%s" "$out" | grep -q secret'                "hidden alias not listed"
check '[ "$(printf "%s\n" "$out" | grep "│ [a-z]" | sed -n 1p | awk "{print \$2, \$3}")" = "db *" ]' "pinned alias first, starred"
out=$(ok ls --all </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q secret'                  "--all shows hidden"

begin "status --json is valid JSON with prefs data"
cat > "$CFG" <<'EOF'
Host dead
    HostName 127.0.0.1
    Port 9
EOF
printf 'last_connect_dead=2026-07-01 10:00\n' > "$PREFS"
ok status --json </dev/null > "$H/st" 2>/dev/null
check 'python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d[0][\"alias\"]==\"dead\" and d[0][\"reachable\"] is False and d[0][\"last_connect\"]==\"2026-07-01 10:00\"" "$H/st"' "json content"

begin "audit flags old and missing keys; startup warning agrees"
keygen "$H/.ssh/id_ed25519_old"; touch -t 202001010000 "$H/.ssh/id_ed25519_old"
keygen "$H/.ssh/id_ed25519_new"
keygen "$H/elsewhere_key"; touch -t 202001010000 "$H/elsewhere_key"
cat > "$CFG" <<EOF
Host old
    IdentityFile $H/.ssh/id_ed25519_old
Host new
    IdentityFile $H/.ssh/id_ed25519_new
Host gone
    IdentityFile $H/.ssh/id_ed25519_gone
Host skip
    IdentityFile $H/.ssh/id_ed25519_old
Host outside
    IdentityFile $H/elsewhere_key
EOF
printf 'audit_threshold_skip=off\n' > "$PREFS"
out=$(ok audit </dev/null 2>&1)
check 'printf "%s" "$out" | grep -q "old .*key >90 days old"'    "old key flagged"
check 'printf "%s" "$out" | grep -q "new .*key is current"'      "fresh key current"
check 'printf "%s" "$out" | grep -q "gone .*key file not found"' "missing key flagged"
check 'printf "%s" "$out" | grep -q "skip .*auditing disabled"'  "per-alias off"
check 'printf "%s" "$out" | grep -q "outside .*key >90 days old"' "keys outside ~/.ssh audited"
check 'printf "%s" "$out" | grep -q "3 key(s) flagged"'          "summary count"

begin "agent list sees loaded keys"
keygen "$H/.ssh/id_ed25519_web"; keygen "$H/.ssh/id_ed25519_db"
printf 'Host web\n    IdentityFile %s/.ssh/id_ed25519_web\nHost db\n    IdentityFile %s/.ssh/id_ed25519_db\n' "$H" "$H" > "$CFG"
eval "$(ssh-agent -s)" >/dev/null
ssh-add -q "$H/.ssh/id_ed25519_web" 2>/dev/null
out=$(ok agent list </dev/null 2>&1)
check 'printf "%s\n" "$out" | grep -q "^  web  *yes"'           "loaded key → yes"
check 'printf "%s\n" "$out" | grep -q "^  db  *no"'             "other key → no"
ssh-agent -k >/dev/null 2>&1

begin "snippet named 'snippet' survives the old-format migration"
printf '[snippet]\ndescription=d\ncommand=uptime\nuse_sudo=no\ncreated=x\n\n' > "$H/.config/okssh/snippets"
ok snip ls </dev/null >/dev/null 2>&1
check 'has "$H/.config/okssh/snippets" "[snippet]"'          "snippet kept"
check 'has "$H/.config/okssh/snippets" "command=uptime"'     "fields kept"

begin "import reads every alias from the file (prompts don't eat lines)"
printf 'Host keep\n    HostName 192.0.2.1\n' > "$CFG"
cat > "$H/imp.txt" <<'EOF'
[alias]
name=one
hostname=127.0.0.1
user=root
port=9

[alias]
name=two
hostname=127.0.0.1
user=root
port=9

[alias]
name=three
hostname=127.0.0.1
user=root
port=9
EOF
printf '\n\n\n\n\n\n' | ok import "$H/imp.txt" >/dev/null 2>&1
check 'grep -qx "Host one" "$CFG" && grep -qx "Host two" "$CFG" && grep -qx "Host three" "$CFG"' "all three imported"

begin "key sync: no terminal → stale flag, archive untouched"
keygen "$H/.ssh/id_ed25519_web"
mkdir -p "$H/sync"
printf 'sync_path=%s/sync\nkeys_sync=enabled\n' "$H" > "$PREFS"
printf 'right-pass\nright-pass\n' | ok sync keys update >/dev/null 2>&1
check '[ -f "$H/sync/keys.enc" ]'                              "first build (passphrase twice)"
cp "$H/sync/keys.enc" "$H/enc.before"
printf 'Host web\n    IdentityFile %s/.ssh/id_ed25519_web\n' "$H" > "$CFG"
ok tag web x </dev/null >/dev/null 2>&1          # no-op for keys sync; then rm triggers it
ok rm web --yes </dev/null >/dev/null 2>&1
check 'has "$PREFS" "keys_sync_stale=1"'                     "stale flag set"
check 'cmp -s "$H/sync/keys.enc" "$H/enc.before"'           "archive not rewritten"
printf 'wrong-pass\n' | ok sync keys update >/dev/null 2>&1; rc=$?
check '[ "$rc" != 0 ]'                                        "wrong passphrase refused"
check 'cmp -s "$H/sync/keys.enc" "$H/enc.before"'           "archive untouched by wrong passphrase"
printf 'right-pass\n' | ok sync keys update >/dev/null 2>&1
check '! grep -q "^keys_sync_stale=" "$PREFS"'               "correct passphrase clears the flag"
check 'printf right-pass | openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass stdin -in "$H/sync/keys.enc" | tar -tf - >/dev/null 2>&1' "archive decrypts"

begin "key sync: first build with mismatched passphrases is refused"
keygen "$H/.ssh/id_ed25519_web"
mkdir -p "$H/sync"
printf 'sync_path=%s/sync\nkeys_sync=enabled\n' "$H" > "$PREFS"
printf 'one\ntwo\n' | ok sync keys update >/dev/null 2>&1
check '! [ -f "$H/sync/keys.enc" ]'                            "no archive written"

begin "rotate against an unreachable host aborts cleanly"
keygen "$H/.ssh/id_ed25519_dead"
printf 'Host dead\n    HostName 127.0.0.1\n    Port 9\n    User root\n    IdentityFile %s/.ssh/id_ed25519_dead\n' "$H" > "$CFG"
cp "$CFG" "$H/before"
printf 'y\n\n\n' | ok rotate dead >/dev/null 2>&1; rc=$?
check '[ "$rc" != 0 ]'                                        "rotate fails"
check 'cmp -s "$CFG" "$H/before"'                            "config unchanged"
check '[ -f "$H/.ssh/id_ed25519_dead" ] && ! [ -e "$H/.ssh/id_ed25519_dead_new" ]' "old key kept, new key cleaned up"

# ── summary ───────────────────────────────────────────────────────────────────
printf '\n%d passed, %d failed  (okssh under %s)\n' "$PASS" "$FAIL" "$OKSSH_SH"
[ "$FAIL" -eq 0 ]
