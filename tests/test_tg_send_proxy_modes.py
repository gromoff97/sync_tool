import importlib.util
import pathlib
import unittest
from types import SimpleNamespace


def load_tg_send_module():
    module_path = pathlib.Path(__file__).resolve().parents[1] / "src" / "tg_send.py"
    spec = importlib.util.spec_from_file_location("tg_send", module_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class TelegramProxyConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tg_send = load_tg_send_module()

    def test_invalid_proxy_type_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "must be one of"):
            self.tg_send.validate_proxy_type("ftp")

    def test_none_proxy_type_disallows_proxy_keys(self):
        with self.assertRaisesRegex(ValueError, "not allowed"):
            self.tg_send.resolve_configured_proxy_mode(
                proxy_type="none",
                socks5_host="127.0.0.1",
                socks5_port="1080",
            )

    def test_socks5_proxy_type_builds_transport_mode(self):
        mode = self.tg_send.resolve_configured_proxy_mode(
            proxy_type="socks5",
            socks5_host="127.0.0.1",
            socks5_port="1080",
            socks5_user="alice",
            socks5_password="secret",
        )

        self.assertEqual("socks5", mode.kind)
        self.assertEqual("127.0.0.1", mode.host)
        self.assertEqual(1080, mode.port)
        self.assertEqual("alice", mode.user)
        self.assertEqual("secret", mode.password)

    def test_http_proxy_type_builds_transport_mode(self):
        mode = self.tg_send.resolve_configured_proxy_mode(
            proxy_type="http",
            http_host="proxy.example.com",
            http_port="8080",
            http_user="alice",
            http_password="secret",
        )

        self.assertEqual("http", mode.kind)
        self.assertEqual("proxy.example.com", mode.host)
        self.assertEqual(8080, mode.port)
        self.assertEqual("alice", mode.user)
        self.assertEqual("secret", mode.password)

    def test_http_proxy_type_rejects_partial_credentials(self):
        with self.assertRaisesRegex(ValueError, "supplied together"):
            self.tg_send.resolve_configured_proxy_mode(
                proxy_type="http",
                http_host="proxy.example.com",
                http_port="8080",
                http_user="alice",
            )

    def test_mtproto_proxy_type_rejects_non_hex_secret(self):
        with self.assertRaisesRegex(ValueError, "hexadecimal"):
            self.tg_send.resolve_configured_proxy_mode(
                proxy_type="mtproto",
                mtproto_host="proxy.example.com",
                mtproto_port="443",
                mtproto_secret="xyz",
            )

    def test_mtproto_proxy_type_rejects_odd_length_secret(self):
        with self.assertRaisesRegex(ValueError, "hexadecimal"):
            self.tg_send.resolve_configured_proxy_mode(
                proxy_type="mtproto",
                mtproto_host="proxy.example.com",
                mtproto_port="443",
                mtproto_secret="abc",
            )

    def test_mtproto_proxy_type_builds_mtproto_mode(self):
        mode = self.tg_send.resolve_configured_proxy_mode(
            proxy_type="mtproto",
            mtproto_host="proxy.example.com",
            mtproto_port="443",
            mtproto_secret="ab" * 16,
        )

        self.assertEqual("mtproto", mode.kind)
        self.assertEqual("proxy.example.com", mode.host)
        self.assertEqual(443, mode.port)
        self.assertEqual("ab" * 16, mode.secret)

    def test_socks5_mode_disallows_mtproto_keys(self):
        with self.assertRaisesRegex(ValueError, "not allowed"):
            self.tg_send.resolve_configured_proxy_mode(
                proxy_type="socks5",
                socks5_host="127.0.0.1",
                socks5_port="1080",
                mtproto_host="proxy.example.com",
            )

    def test_resolve_proxy_mode_from_args_defaults_to_none(self):
        mode = self.tg_send.resolve_proxy_mode_from_config(
            SimpleNamespace(
                proxy_type="",
                socks5_host="",
                socks5_port="",
                socks5_user="",
                socks5_password="",
                http_host="",
                http_port="",
                http_user="",
                http_password="",
                mtproto_host="",
                mtproto_port="",
                mtproto_secret="",
            )
        )

        self.assertEqual("none", mode.kind)
        self.assertEqual("", mode.host)
        self.assertEqual(0, mode.port)

    def test_resolve_proxy_mode_from_args_builds_http_mode(self):
        mode = self.tg_send.resolve_proxy_mode_from_config(
            SimpleNamespace(
                proxy_type="http",
                socks5_host="",
                socks5_port="",
                socks5_user="",
                socks5_password="",
                http_host="proxy.example.com",
                http_port="8080",
                http_user="alice",
                http_password="secret",
                mtproto_host="",
                mtproto_port="",
                mtproto_secret="",
            )
        )

        self.assertEqual("http", mode.kind)
        self.assertEqual("proxy.example.com", mode.host)
        self.assertEqual(8080, mode.port)
        self.assertEqual("alice", mode.user)
        self.assertEqual("secret", mode.password)

    def test_windows_session_path_is_normalized_for_wsl(self):
        normalized = self.tg_send.normalize_session_path(
            r"C:\Users\gromoff97\.sync_tool_telegram"
        )

        self.assertTrue(
            normalized in (
                r"C:\Users\gromoff97\.sync_tool_telegram",
                "/mnt/c/Users/gromoff97/.sync_tool_telegram",
            )
        )


if __name__ == "__main__":
    unittest.main()
