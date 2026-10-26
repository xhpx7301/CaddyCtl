"""Linux regression tests; all files live in a temporary sandbox, no daemon is started.

Run as root: python3 -m unittest discover -s tests -v
"""

import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.name == "posix" and os.geteuid() == 0, "requires Linux root")
class CaddyPermissionsTest(unittest.TestCase):
    def setUp(self):
        self.sandbox = Path(tempfile.mkdtemp(prefix="caddyctl-permissions-"))
        self.sandbox.chmod(0o755)
        self.addCleanup(shutil.rmtree, self.sandbox)
        source = (Path(__file__).resolve().parents[1] / "caddyctl.sh").read_text()
        source = source.split('if [[ $# -eq 1 && ( "$1" == "--help"')[0]
        paths = {
            "CADDY_CONFIG_DIR": "etc",
            "CADDYFILE": "etc/Caddyfile",
            "SITES_DIR": "etc/sites",
            "CADDY_DATA_DIR": "data",
            "BACKUP_DIR": "backups",
            "CADDY_L4_STATE_FILE": "etc/state.tsv",
            "CADDY_L4_SERVICE_DROPIN": "service/l4.conf",
            "CADDY_L4_BINARY": "caddy-l4",
            "REAL_CADDY": "check-runtime",
        }
        for name, relative in paths.items():
            source = re.sub(
                rf'^readonly {name}=.*$',
                f'readonly {name}="{self.sandbox / relative}"',
                source,
                flags=re.MULTILINE,
            )
        self.library = self.sandbox / "library.sh"
        self.library.write_text(source)
        # A small executable probes actual OS permissions and the validation identity.
        # It deliberately does not emulate the Caddy configuration parser.
        runtime = self.sandbox / "check-runtime"
        runtime.write_text(
            '#!/bin/bash\nset -euo pipefail\n'
            '[[ "$(id -un)" == nobody && "$(id -gn)" == nogroup ]]\n'
            '[[ "$XDG_CONFIG_HOME" == "$HOME/.config" ]]\n'
            '[[ "$XDG_DATA_HOME" == "$HOME/.local/share" ]]\n'
            'cat "$3" >/dev/null\n'
            'for site in "$(dirname "$3")"/sites/*.caddy; do\n'
            '  [[ ! -f "$site" ]] || cat "$site" >/dev/null\n'
            'done\n'
            'touch "$HOME/validation-probe"\n'
        )
        runtime.chmod(0o755)

    def run_shell(self, body):
        harness = '''
set -euo pipefail
source "$1"
systemctl() {
  case "$*" in
    *--property=User*) echo nobody ;;
    *--property=Group*) echo nogroup ;;
    *) echo "$*" >>"$CADDY_CONFIG_DIR/../systemctl.log" ;;
  esac
}
'''
        result = subprocess.run(
            ["bash", "-c", harness + body, "test", str(self.library)],
            capture_output=True, text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_repairs_reported_permissions_without_exposing_state_or_certificates(self):
        self.run_shell('''
install -d -m 0750 "$CADDY_CONFIG_DIR"
echo '# empty configuration' >"$CADDYFILE"
echo secret >"$CADDY_L4_STATE_FILE"
chmod 0600 "$CADDY_L4_STATE_FILE"
! runuser -u nobody -- test -r "$CADDYFILE"
validate_caddy_config "$REAL_CADDY"
[[ "$(stat -c '%U:%G:%a' "$CADDY_CONFIG_DIR")" == root:nogroup:750 ]]
[[ "$(stat -c '%U:%G:%a' "$CADDY_DATA_DIR")" == nobody:nogroup:750 ]]
! runuser -u nobody -- test -r "$CADDY_L4_STATE_FILE"
echo private >"$CADDY_DATA_DIR/certificate"
chmod 0600 "$CADDY_DATA_DIR/certificate"
prepare_caddy_permissions
[[ "$(stat -c '%U:%G:%a' "$CADDY_DATA_DIR/certificate")" == root:root:600 ]]
''')

    def test_initialization_with_restrictive_umask(self):
        self.run_shell('''
umask 077
initialize_caddyfile
validate_caddy_config "$REAL_CADDY"
runuser -u nobody -- test -r "$CADDYFILE"
''')

    def test_layer4_rewrite_and_removal_preserve_metadata(self):
        self.run_shell('''
initialize_caddyfile
chmod 0640 "$CADDYFILE"
cp -a "$CADDYFILE" "$CADDY_CONFIG_DIR/original"
printf 'R\\treality.example\\t127.0.0.1\\t15443\\n' >"$CADDY_L4_STATE_FILE"
write_caddy_l4_block panel.example 127.0.0.1:20534
[[ "$(stat -c '%U:%G:%a' "$CADDYFILE")" == root:nogroup:640 ]]
grep -Fq 'alpn http/1.1 http/1.0' "$CADDYFILE"
grep -Fq 'alpn http/1.1' "$CADDYFILE"
remove_caddy_l4_block
[[ "$(stat -c '%U:%G:%a' "$CADDYFILE")" == root:nogroup:640 ]]
! grep -q 'listener_wrappers' "$CADDYFILE"
validate_caddy_config "$REAL_CADDY"
''')

    def test_unreadable_site_blocks_reload(self):
        self.run_shell('''
initialize_caddyfile
echo 'private configuration' >"$SITES_DIR/private.caddy"
chmod 0600 "$SITES_DIR/private.caddy"
caddy_runtime_binary() { echo "$REAL_CADDY"; }
if reload_validated_config; then exit 1; fi
[[ ! -f "$CADDY_CONFIG_DIR/../systemctl.log" ]]
''')

    def test_disable_and_failed_disable_rollback(self):
        for fail in (False, True):
            with self.subTest(failed_validation=fail):
                self.run_shell('''
initialize_caddyfile
chmod 0640 "$CADDYFILE"
printf 'R\\treality.example\\t127.0.0.1\\t15443\\n' >"$CADDY_L4_STATE_FILE"
write_caddy_l4_block panel.example 127.0.0.1:20534
install -d "$(dirname "$CADDY_L4_SERVICE_DROPIN")"
echo "$CADDY_L4_BINARY run" >"$CADDY_L4_SERVICE_DROPIN"
cp -a "$CADDYFILE" "$CADDY_CONFIG_DIR/original"
confirm_action() { return 0; }
''' + ('''
echo private >"$SITES_DIR/private.caddy"
chmod 0600 "$SITES_DIR/private.caddy"
if disable_caddy_l4; then exit 1; fi
cmp "$CADDYFILE" "$CADDY_CONFIG_DIR/original"
[[ -f "$CADDY_L4_SERVICE_DROPIN" ]]
rm "$SITES_DIR/private.caddy"
''' if fail else '''
disable_caddy_l4
[[ ! -f "$CADDY_L4_SERVICE_DROPIN" ]]
! grep -q 'listener_wrappers' "$CADDYFILE"
''') + '''
[[ "$(stat -c '%U:%G:%a' "$CADDYFILE")" == root:nogroup:640 ]]
''')


if __name__ == "__main__":
    unittest.main()
