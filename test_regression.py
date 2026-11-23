import json
import re
from urllib.parse import unquote, urlsplit
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).with_name("vless-reality-cf.sh")
SOURCE = SCRIPT.read_text()
FUNCTIONS, CLI = SOURCE.split('XRAY_VERSION="26.11.9"', 1)


class RegressionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vless-local-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cfg = self.root / "etc/vless-reality-cf"
        self.users = self.cfg / "users"
        self.users.mkdir(parents=True)
        self.nginx_dir = self.root / "etc/nginx"
        (self.nginx_dir / "stream.conf.d").mkdir(parents=True)
        self.binary = self.root / "usr/local/bin/xray"
        self.binary.parent.mkdir(parents=True)
        self.config = self.cfg / "xray.json"
        self.db = self.cfg / "db.json"
        self.db.write_text(json.dumps({
            "port": 443, "sni": "speed.cloudflare.com", "private_key": "test-private",
            "public_key": "test-public", "short_ids": "0123456789abcdef",
            "short_id": "0123456789abcdef", "default_uuid": "never-resurrect",
        }))
        (self.cfg / "private.key").write_text("test-private\n")
        (self.cfg / "public.key").write_text("test-public\n")
        self.functions = self.remap(FUNCTIONS)
        self.guards = "\n".join(
            f'{name}() {{ printf "UNEXPECTED COMMAND: {name}\\n" >&2; exit 99; }}'
            for name in ["curl", "wget", "ssh", "scp", "apk", "dnf", "yum", "apt-get",
                         "systemctl", "rc-service", "rc-update", "firewall-cmd", "ufw"]
        )
        self.prelude = self.guards + "\n" + self.functions + """
R= G= Y= C= W= D= NC=
_header() { :; }
_line() { :; }
_dline() { :; }
_item() { :; }
_info() { :; }
_ok() { printf 'OK:%s\n' "$*"; }
_warn() { printf 'WARN:%s\n' "$*" >&2; }
_err() { printf 'ERROR:%s\n' "$*" >&2; }
sleep() { :; }
XRAY_VERSION=26.11.9
"""

    def remap(self, text):
        for prefix in ["/usr/local", "/etc", "/var/log"]:
            text = text.replace(prefix, str(self.root) + prefix)
        return text

    def run_shell(self, code, stdin="", expected=0, extra_env=None):
        env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.root),
               "LC_ALL": "en_US.UTF-8"}
        env.update(extra_env or {})
        result = subprocess.run(
            ["/bin/bash", "-c", self.prelude + "\n" + code],
            input=stdin, text=True, errors="replace", capture_output=True,
            cwd=self.root, env=env, timeout=10,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("UNEXPECTED COMMAND", result.stderr)
        return result

    def user(self, name, enabled="missing"):
        data = {"uuid": name, "email": name}
        if enabled != "missing":
            data["enabled"] = enabled
        (self.users / f"{name}.json").write_text(json.dumps(data))

    def xray(self, version="26.11.9", validation=0):
        self.binary.write_text(
            '#!/bin/sh\nif [ "$1" = version ]; then printf "Xray ' + version +
            '\\n"; exit 0; fi\n'
            'while [ "$#" -gt 0 ]; do\n'
            '  case "$1" in\n'
            '    -c|-config)\n'
            '      shift\n'
            '      case "$1" in *.json) ;; *) exit 23 ;; esac\n'
            '      [ -f "$1" ] || exit 23\n'
            '      ;;\n'
            '  esac\n'
            '  shift\n'
            'done\n'
            'exit ' + str(validation) + '\n'
        )
        self.binary.chmod(0o755)

    def archive(self, version="26.11.9", validation=0):
        archive = self.root / "release.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("xray", '#!/bin/sh\nif [ "$1" = version ]; then printf "Xray ' +
                       version + '\\n"; exit 0; fi\nexit ' + str(validation) + '\n')
            z.writestr("geoip.dat", "test-data")
        return f'''
uname() {{ printf 'x86_64\\n'; }}
curl() {{
    local output
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -o ]]; then output="$2"; shift 2; else shift; fi
    done
    cp {shlex.quote(str(archive))} "$output"
}}
'''

    def nginx_mock(self, files):
        mock = self.root / "nginx_mock.py"
        mock.write_text('''import os, re, sys
from pathlib import Path
main = Path(os.environ["NGINX_MAIN"])
target = Path(os.environ["NGINX_TARGET"])
files = [main] + [Path(p) for p in os.environ["NGINX_LOADED"].split(":") if p]
if sys.argv[1] == "-V":
    print("--with-stream --with-stream_ssl_preread_module")
    sys.exit(0)
active = ["\\n".join(line.split("#", 1)[0] for line in f.read_text().splitlines()) for f in files]
if any("BROKEN" in text for text in active):
    sys.exit(1)
if sum(len(re.findall(r"\\bstream\\s*\\{", text)) for text in active) > 1:
    sys.exit(1)
loaded = any(str(target.parent) + "/*.conf" in text for text in active)
for f in files + ([target] if loaded and target.exists() else []):
    print("# configuration file " + str(f) + ":")
    print(f.read_text())
''')
        import sys
        return f'nginx() {{ {shlex.quote(sys.executable)} {shlex.quote(str(mock))} "$@"; }}\n', {
            "NGINX_MAIN": str(self.nginx_dir / "nginx.conf"),
            "NGINX_TARGET": str(self.nginx_dir / "stream.conf.d/vless-reality-sni.conf"),
            "NGINX_LOADED": ":".join(map(str, files)),
        }

    def test_enabled_false_null_missing_and_true(self):
        for name, value in [("legacy", "missing"), ("active", True), ("disabled", False), ("null", None)]:
            self.user(name, value)
        result = self.run_shell("build_clients_json")
        self.assertEqual([x["id"] for x in json.loads(result.stdout)], ["active", "legacy"])

    def test_all_disabled_and_empty_never_restore_default(self):
        self.user("disabled", False)
        self.assertEqual(json.loads(self.run_shell("build_clients_json").stdout), [])
        (self.users / "disabled.json").unlink()
        self.assertEqual(json.loads(self.run_shell("build_clients_json").stdout), [])

    def test_malformed_user_fails(self):
        (self.users / "broken.json").write_text("{")
        self.assertNotEqual(self.run_shell("build_clients_json", expected=None).returncode, 0)

    def test_empty_clients_config_is_not_repopulated(self):
        self.xray()
        self.run_shell("generate_xray_config")
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["settings"]["clients"], [])
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(list(self.cfg.glob(".xray.*")), [])

    def test_invalid_candidate_config_preserves_existing(self):
        self.xray(validation=1)
        self.config.write_text("original")
        self.run_shell("generate_xray_config", expected=1)
        self.assertEqual(self.config.read_text(), "original")
        self.assertEqual(list(self.cfg.glob(".xray.*")), [])

    def test_failed_revocation_stops_service(self):
        result = self.run_shell('''
generate_xray_config() { return 1; }
svc() { printf 'SERVICE:%s\n' "$*"; }
apply_xray_changes
''', expected=1)
        self.assertIn("SERVICE:stop vless-reality", result.stdout)

    def test_toggle_changes_clients_both_directions(self):
        self.user("active", True)
        self.xray()
        self.run_shell("restart_xray() { :; }; toggle_user", stdin="1\n")
        self.assertFalse(json.loads((self.users / "active.json").read_text())["enabled"])
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["settings"]["clients"], [])
        self.run_shell("restart_xray() { :; }; toggle_user", stdin="1\n")
        self.assertTrue(json.loads((self.users / "active.json").read_text())["enabled"])

    def test_delete_last_user_rejects_default(self):
        self.user("active", True)
        self.xray()
        self.run_shell("restart_xray() { :; }; delete_user", stdin="1\ny\n")
        self.assertFalse((self.users / "active.json").exists())
        self.assertEqual(json.loads(self.config.read_text())["inbounds"][0]["settings"]["clients"], [])

    def test_user_path_traversal_rejected(self):
        self.run_shell("add_user", stdin="../../escape\n", expected=1)
        self.assertFalse((self.root / "etc/escape.json").exists())

    def test_nat_only_uses_outbound_route(self):
        for public, source, status in [("8.8.8.8", "8.8.8.8", 1),
                                      ("8.8.8.8", "100.64.19.37", 0),
                                      ("8.8.8.8", "10.0.0.1", 0),
                                      ("8.8.8.8", "", 1), ("", "10.0.0.1", 1)]:
            with self.subTest(source=source, public=public):
                self.run_shell(f'''
ip() {{ [[ "$*" == '-4 route get 1.1.1.1' ]] || exit 98;
    printf '%s\\n' '1.1.1.1 via 10.0.0.254 dev eth0 src {source}'; }}
ipv4_is_nat '{public}'
''', expected=status)

    def test_port_bounds_and_internal_conflict(self):
        for value in ["1", "443", "65535", "00443"]:
            self.run_shell(f"valid_port '{value}'")
        for value in ["0", "65536", "8443", "08443", "-1", "", "abc", "12345678901234567890", "1;id"]:
            self.run_shell(f"valid_port '{value}'", expected=1)

    def test_same_xray_version_skips_download(self):
        self.xray()
        self.run_shell("install_xray")
        self.assertFalse(Path(str(self.binary) + ".previous").exists())

    def test_xray_download_failure_preserves_binary(self):
        self.xray("old")
        old = self.binary.read_bytes()
        self.run_shell("curl() { return 22; }; install_xray", expected=1)
        self.assertEqual(self.binary.read_bytes(), old)
        self.assertEqual(list(self.binary.parent.glob(".xray.*")), [])

    def test_xray_wrong_version_preserves_binary(self):
        self.xray("old")
        old = self.binary.read_bytes()
        self.run_shell(self.archive("wrong") + "install_xray", expected=1)
        self.assertEqual(self.binary.read_bytes(), old)

    def test_xray_rejects_existing_config_before_replacement(self):
        self.xray("old")
        old = self.binary.read_bytes()
        self.config.write_text("original")
        self.run_shell(self.archive(validation=1) + "install_xray", expected=1)
        self.assertEqual(self.binary.read_bytes(), old)

    def test_xray_upgrade_backups_and_replaces_inode(self):
        self.xray("old")
        old, inode = self.binary.read_bytes(), self.binary.stat().st_ino
        self.run_shell(self.archive() + "install_xray")
        self.assertNotEqual(self.binary.stat().st_ino, inode)
        self.assertEqual(Path(str(self.binary) + ".previous").read_bytes(), old)
        self.assertIn("26.11.9", self.binary.read_text())

    def test_dependency_failure_precedes_network_discovery(self):
        result = self.run_shell('''
PKG_MGR=apk; SVC_MGR=openrc
install_deps() { printf 'deps\n'; return 1; }
get_ipv4() { printf 'unexpected-ipv4\n'; }
do_install
''', expected=1)
        self.assertIn("deps", result.stdout)
        self.assertNotIn("unexpected-ipv4", result.stdout)

    def install_stubs(self):
        return '''
PKG_MGR=apk; SVC_MGR=openrc
install_deps() { :; }; install_nginx() { :; }; install_xray() { :; }
open_firewall_port() { :; }
generate_xray_config() { :; }; generate_nginx_sni_config() { :; }
'''

    def test_reinstall_preserves_credentials_and_disabled_users(self):
        self.user("disabled", False)
        self.config.write_text("existing")
        before = {p: p.read_bytes() for p in self.cfg.rglob("*") if p.is_file()}
        result = self.run_shell(self.install_stubs() + '''
gen_keys() { printf 'unexpected-keys'; return 1; }
start_proxy_services() { printf 'restarted\n'; }
do_install
''')
        self.assertIn("restarted", result.stdout)
        self.assertNotIn("unexpected-keys", result.stdout)
        self.assertEqual(before, {p: p.read_bytes() for p in self.cfg.rglob("*") if p.is_file()})

    def test_reinstall_service_failure_never_reports_success(self):
        result = self.run_shell(self.install_stubs() + "start_proxy_services() { return 1; }; do_install", expected=1)
        self.assertNotIn("OK:重装完成", result.stdout)
        self.assertNotIn("安装完成!", result.stdout)

    def test_fresh_service_failure_never_reports_success(self):
        (self.cfg / "private.key").unlink()
        (self.cfg / "public.key").unlink()
        self.db.write_text('{"port":443}')
        result = self.run_shell(self.install_stubs() + '''
get_ipv4() { printf '8.8.8.8'; }; get_ipv6() { :; }; ipv4_is_nat() { return 1; }
select_sni_domain() { SELECTED_SNI=speed.cloudflare.com; }
gen_keys() { printf test > "$CFG/private.key"; printf public > "$CFG/public.key"; }
gen_uuid() { printf test-uuid; }; gen_short_ids() { printf 0123456789abcdef; }
gen_random_port() { printf 12345; }
start_proxy_services() { return 1; }
do_install
''', stdin="1\n", expected=1)
        self.assertNotIn("安装完成!", result.stdout)

    def test_running_services_are_restarted_not_started(self):
        self.xray()
        result = self.run_shell('''
nginx() { :; }; create_nginx_service() { :; }; create_xray_service() { :; }
is_service_active() { return 0; }
svc() { printf 'SERVICE:%s\n' "$*"; }
start_proxy_services
''')
        self.assertIn("SERVICE:restart vless-reality", result.stdout)
        self.assertIn("SERVICE:restart nginx", result.stdout)
        self.assertNotIn("SERVICE:start ", result.stdout)

    def test_failed_restart_returns_error_and_requests_stop(self):
        self.xray()
        result = self.run_shell('''
nginx() { :; }; create_nginx_service() { :; }; create_xray_service() { :; }
is_service_active() { return 0; }
svc() { printf 'SERVICE:%s\n' "$*"; [[ "$1" == stop ]]; }
start_proxy_services
''', expected=1)
        self.assertIn("SERVICE:stop vless-reality", result.stdout)

    def test_nginx_loaded_stream_variants_are_idempotent(self):
        main = self.nginx_dir / "nginx.conf"
        target = self.nginx_dir / "stream.conf.d/vless-reality-sni.conf"
        for content in ["stream { }\n", "stream\n{\n}\n", "stream {\n}\n"]:
            with self.subTest(content=content):
                main.write_text(content)
                target.write_text("map $a $b { default x; }\n")
                mock, env = self.nginx_mock([])
                self.run_shell(mock + "ensure_nginx_stream_include; ensure_nginx_stream_include", extra_env=env)
                self.assertEqual(main.read_text().count("include "), 1)

    def test_nginx_ignores_orphan_and_comment_preserves_symlink(self):
        main = self.nginx_dir / "nginx.conf"
        real = self.nginx_dir / "actual.conf"
        real.write_text("# stream.conf.d is not an include\nstream {}\n")
        real.chmod(0o640)
        main.symlink_to(real)
        orphan = self.nginx_dir / "orphan.conf"
        orphan.write_text("stream {}\n")
        (self.nginx_dir / "stream.conf.d/vless-reality-sni.conf").write_text("map $a $b { default x; }\n")
        mock, env = self.nginx_mock([])
        self.run_shell(mock + "ensure_nginx_stream_include", extra_env=env)
        self.assertTrue(main.is_symlink())
        self.assertEqual(real.stat().st_mode & 0o777, 0o640)
        self.assertEqual(orphan.read_text(), "stream {}\n")

    def test_nginx_loaded_secondary_file_is_target(self):
        main = self.nginx_dir / "nginx.conf"
        main.write_text("events {}\n")
        stream = self.nginx_dir / "loaded.conf"
        stream.write_text("stream {}\n")
        (self.nginx_dir / "stream.conf.d/vless-reality-sni.conf").write_text("map $a $b { default x; }\n")
        mock, env = self.nginx_mock([stream])
        self.run_shell(mock + "ensure_nginx_stream_include", extra_env=env)
        self.assertIn("include ", stream.read_text())
        self.assertEqual(main.read_text(), "events {}\n")

    def test_nginx_failed_postcheck_restores_main_config(self):
        main = self.nginx_dir / "nginx.conf"
        original = "stream {}\n"
        main.write_text(original)
        result = self.run_shell('''
nginx() {
    if [[ "$1" == -T ]] && ! command grep -q 'include ' "''' + str(main) + '''"; then
        printf '# configuration file %s:\n' "''' + str(main) + '''"
    else return 1; fi
}
ensure_nginx_stream_include
''', expected=1)
        self.assertEqual(main.read_text(), original)
        self.assertIn("恢复", result.stderr)

    def test_nginx_failed_sni_write_rolls_back(self):
        target = self.nginx_dir / "stream.conf.d/vless-reality-sni.conf"
        for exists in [True, False]:
            with self.subTest(exists=exists):
                if exists:
                    target.write_text("original")
                elif target.exists():
                    target.unlink()
                self.run_shell('''
ensure_stream_module_loaded() { :; }
ensure_nginx_stream_include() { return 1; }
generate_nginx_sni_config
''', expected=1)
                self.assertEqual(target.exists(), exists)
                if exists:
                    self.assertEqual(target.read_text(), "original")

    def test_selinux_port_ranges_and_existing_relay_need_no_changes(self):
        self.run_shell('''
getenforce() { printf Enforcing; }
semanage() { [[ "$*" == 'port -l' ]] || exit 98; printf 'http_port_t tcp 80, 443, 8000-9000\n'; }
getsebool() { printf 'httpd_can_network_relay --> on'; }
setsebool() { exit 98; }
configure_selinux_proxy 443
''')

    def test_selinux_changes_require_consent(self):
        self.run_shell('''
getenforce() { printf Enforcing; }
semanage() { [[ "$*" == 'port -l' ]] || exit 98; printf 'http_port_t tcp 80, 443\n'; }
getsebool() { printf 'httpd_can_network_relay --> off'; }
setsebool() { exit 98; }
configure_selinux_proxy 443
''', stdin="n\n", expected=1)

    def test_selinux_add_failure_is_not_hidden(self):
        self.run_shell('''
getenforce() { printf Enforcing; }
semanage() { if [[ "$*" == 'port -l' ]]; then printf 'other_port_t tcp 8443\n'; else return 1; fi; }
getsebool() { printf 'httpd_can_network_relay --> off'; }
setsebool() { exit 98; }
configure_selinux_proxy 443
''', stdin="y\n", expected=1)

    def test_firewalld_does_not_reload(self):
        result = self.run_shell('''
configure_selinux_proxy() { :; }
check_cmd() { [[ "$1" == firewall-cmd ]]; }
firewall-cmd() { printf 'FIREWALL:%s\n' "$*"; }
open_firewall_port 443
''')
        self.assertIn("--add-port=443/tcp", result.stdout)
        self.assertIn("--permanent --add-port=443/tcp", result.stdout)
        self.assertNotIn("--reload", result.stdout)

    def test_sh_bootstrap_and_bash_syntax(self):
        for args in [["/bin/bash", "-n", str(SCRIPT)], ["/bin/sh", str(SCRIPT), "--help"]]:
            result = subprocess.run(args, text=True, capture_output=True, timeout=5,
                                    env={"PATH": "/usr/bin:/bin", "HOME": str(self.root)})
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_nginx_adds_first_stream_block(self):
        main = self.nginx_dir / "nginx.conf"
        main.write_text("events {}\n")
        target = self.nginx_dir / "stream.conf.d/vless-reality-sni.conf"
        target.write_text("map $a $b { default x; }\n")
        mock, env = self.nginx_mock([])
        self.run_shell(mock + "ensure_nginx_stream_include", extra_env=env)
        self.assertIn("stream {", main.read_text())
        self.assertEqual(main.read_text().count("include "), 1)

    def settings_fixture(self):
        self.config.write_text("original-xray")
        target = self.nginx_dir / "stream.conf.d/vless-reality-sni.conf"
        target.write_text("original-nginx")
        return {p: p.read_bytes() for p in [self.db, self.config, target]}

    def test_port_restart_failure_restores_files_and_services(self):
        before = self.settings_fixture()
        result = self.run_shell('''
open_firewall_port() { :; }; is_service_active() { return 0; }
generate_xray_config() { printf new-xray > "$XRAY_CONFIG"; }
generate_nginx_sni_config() { printf new-nginx > "$NGINX_SNI_CONF"; }
restart_xray() { printf 'xray-restart\n'; }
restart_nginx() { [[ "$(db_get_field '.port')" == 443 ]] && printf 'nginx-restored\n'; }
change_port
''', stdin="1443\n", expected=1)
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertIn("nginx-restored", result.stdout)
        self.assertNotIn("OK:端口已改", result.stdout)
        self.assertFalse(list(self.cfg.glob(".settings.*")))

    def test_sni_generation_failure_restores_database_and_configs(self):
        before = self.settings_fixture()
        self.run_shell('''
is_service_active() { return 0; }
select_sni_domain() { SELECTED_SNI=www.cloudflare.com; }
generate_xray_config() { printf new-xray > "$XRAY_CONFIG"; }
generate_nginx_sni_config() { return 1; }
restart_xray() { exit 98; }; restart_nginx() { exit 98; }
change_sni
''', expected=1)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_sni_success_commits_both_configs_and_restarts(self):
        self.settings_fixture()
        result = self.run_shell('''
is_service_active() { return 0; }
select_sni_domain() { SELECTED_SNI=www.cloudflare.com; }
generate_xray_config() { db_get_field '.sni' > "$XRAY_CONFIG"; }
generate_nginx_sni_config() { db_get_field '.sni' > "$NGINX_SNI_CONF"; }
restart_xray() { printf 'xray-restart\n'; }; restart_nginx() { printf 'nginx-restart\n'; }
change_sni
''')
        self.assertEqual(json.loads(self.db.read_text())["sni"], "www.cloudflare.com")
        self.assertEqual(self.config.read_text().strip(), "www.cloudflare.com")
        self.assertIn("xray-restart", result.stdout)
        self.assertIn("nginx-restart", result.stdout)

    def test_partial_install_reuses_existing_keys(self):
        self.db.write_text('{"port":443}')
        key = (self.cfg / "private.key").read_bytes()
        result = self.run_shell(self.install_stubs() + '''
get_ipv4() { printf '8.8.8.8'; }; get_ipv6() { :; }; ipv4_is_nat() { return 1; }
select_sni_domain() { SELECTED_SNI=speed.cloudflare.com; }
gen_keys() { exit 98; }
gen_uuid() { printf test-uuid; }; gen_short_ids() { printf 0123456789abcdef; }
gen_random_port() { printf 12345; }; show_qr() { :; }
start_proxy_services() { :; }
do_install
''', stdin="1\n")
        self.assertEqual((self.cfg / "private.key").read_bytes(), key)
        self.assertEqual(json.loads(self.db.read_text())["sni"], "speed.cloudflare.com")
        self.assertIn("安装完成!", result.stdout)
        self.assertIn("vless://test-uuid@8.8.8.8:443", (self.cfg / "join.txt").read_text())

    def test_required_packages_fail_explicitly(self):
        for manager in ["apk", "dnf", "yum", "apt"]:
            with self.subTest(manager=manager):
                self.run_shell('PKG_MGR=' + manager + '''
pkg_refresh() { :; }; pkg_install_optional() { :; }; pkg_install() { return 1; }
install_deps
''', expected=1)

    def test_alpine_missing_service_package_is_not_ignored(self):
        self.run_shell('''
PKG_MGR=apk; SVC_MGR=openrc
pkg_install() { [[ "$1" == nginx-openrc ]] || exit 98; return 1; }
install_nginx
''', expected=1)

    def test_default_link_names_use_endpoint_ip(self):
        self.user("default-user", True)
        self.user("custom-user", True)
        data = json.loads(self.db.read_text())
        data["default_uuid"] = "default-user"
        self.db.write_text(json.dumps(data))
        before = {p: p.read_bytes() for p in [self.db, *self.users.glob("*.json")]}
        for ipv4, ipv6 in [("203.0.113.10", ""), ("", "2001:db8::10"),
                           ("203.0.113.10", "2001:db8::10")]:
            with self.subTest(ipv4=ipv4, ipv6=ipv6):
                result = self.run_shell(f'''
get_ipv4() {{ printf '%s' '{ipv4}'; }}
get_ipv6() {{ printf '%s' '{ipv6}'; }}
show_qr() {{ printf 'QR:%s\\n' "$1"; }}
show_user_links
''')
                links = re.findall(r"vless://[^\s\x1b]+", result.stdout)
                self.assertEqual(len(links), 4 * sum(bool(ip) for ip in [ipv4, ipv6]))
                for link in links:
                    parsed = urlsplit(link)
                    expected = "VLESS-" + parsed.hostname if parsed.username == "default-user" else "custom-user"
                    self.assertEqual(unquote(parsed.fragment), expected)
                self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_first_install_nat_names_match_qr_and_saved_link(self):
        self.db.write_text('{"port":443}')
        result = self.run_shell(self.install_stubs() + '''
get_ipv4() { printf '203.0.113.10'; }; get_ipv6() { printf '2001:db8::10'; }
ipv4_is_nat() { return 0; }
select_sni_domain() { SELECTED_SNI=speed.cloudflare.com; }
gen_keys() { exit 98; }
gen_uuid() { printf default-user; }; gen_short_ids() { printf 0123456789abcdef; }
gen_random_port() { printf 12345; }; show_qr() { printf 'QR:%s\\n' "$1"; }
start_proxy_services() { :; }
do_install
''', stdin="1\n")
        links = re.findall(r"vless://[^\s\x1b]+", result.stdout)
        self.assertEqual(len(links), 4)
        for link in links:
            parsed = urlsplit(link)
            self.assertEqual(parsed.username, "default-user")
            self.assertEqual(unquote(parsed.fragment), "VLESS-" + parsed.hostname)
            self.assertEqual(parsed.port, 443)
            self.assertIn("security=reality", parsed.query)
        saved = (self.cfg / "join.txt").read_text().strip()
        self.assertIn(saved, links)
        self.assertEqual(urlsplit(saved).hostname, "2001:db8::10")

    def test_cli_default_and_overrides(self):
        cli = 'XRAY_VERSION="26.11.9"' + CLI
        for args, version in [("--install", "26.11.9"),
                              ("--install --xray-version v1.2.3", "1.2.3"),
                              ("--xray-version=2.3.4 --install", "2.3.4")]:
            with self.subTest(args=args):
                result = self.run_shell('''
check_root() { :; }; do_install() { printf 'VERSION:%s\n' "$XRAY_VERSION"; }
set -- ''' + args + "\n" + cli)
                self.assertIn("VERSION:" + version, result.stdout)

    def test_cli_invalid_versions(self):
        cli = 'XRAY_VERSION="26.11.9"' + CLI
        for args in ["--xray-version", "--xray-version=", "--xray-version latest", "--xray-version ../1.2.3", "--xray-version --install"]:
            with self.subTest(args=args):
                self.run_shell("set -- " + args + "\n" + cli, expected=1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
