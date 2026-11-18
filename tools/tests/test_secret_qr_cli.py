from __future__ import annotations

import json

import pytest

from burrow_tools import qr
from burrow_tools.__main__ import main
from burrow_tools.secret import Secret, SecretError

HEX = "ee00112233445566778899aabbccddeeff" + b"notes.example.org".hex()


class TestSecret:
    def test_hex_roundtrip(self):
        secret = Secret.parse(HEX)
        assert secret.host == "notes.example.org"
        assert secret.key == bytes.fromhex("00112233445566778899aabbccddeeff")
        assert secret.hex() == HEX

    def test_base64_roundtrip(self):
        secret = Secret.parse(HEX)
        assert Secret.parse(secret.base64()) == secret
        assert "=" not in secret.base64()

    def test_uppercase_hex_and_whitespace(self):
        assert Secret.parse(f"  {HEX.upper()}\n").host == "notes.example.org"

    @pytest.mark.parametrize(
        "bad",
        [
            "",
            "dd00112233445566778899aabbccddeeff",  # legacy "secure" secret
            "00112233445566778899aabbccddeeff",  # legacy plain secret
            "ee0011",  # too short
            "ee00112233445566778899aabbccddeeff" + b"Bad_Host".hex(),
            "not a secret at all!",
        ],
    )
    def test_rejects(self, bad):
        with pytest.raises(SecretError):
            Secret.parse(bad)


class TestQR:
    LINK = "https://t.me/proxy?server=notes.example.org&port=443&secret=" + HEX

    def test_terminal(self):
        out = qr.terminal(qr.make(self.LINK))
        assert len(out.splitlines()) > 20
        assert "█" in out

    def test_png(self):
        assert qr.render(qr.make(self.LINK), "png").startswith(b"\x89PNG\r\n\x1a\n")

    def test_svg(self):
        assert b"<svg" in qr.render(qr.make(self.LINK), "svg")

    def test_empty(self):
        with pytest.raises(ValueError):
            qr.make("   ")

    def test_unknown_format(self):
        with pytest.raises(ValueError):
            qr.render(qr.make(self.LINK), "gif")


class TestCLI:
    def test_secret_from_env(self, monkeypatch, capsys):
        monkeypatch.setenv("BURROW_SECRET", HEX)
        assert main(["secret"]) == 0
        assert json.loads(capsys.readouterr().out)["host"] == "notes.example.org"

    def test_missing_secret(self, monkeypatch, capsys):
        monkeypatch.delenv("BURROW_SECRET", raising=False)
        assert main(["probe", "--host", "127.0.0.1"]) == 2
        assert "no secret" in capsys.readouterr().err

    def test_qr_from_text(self, capsys):
        assert main(["qr", "--text", "hello"]) == 0
        assert "█" in capsys.readouterr().out

    def test_probe_json_output(self, monkeypatch, capsys):
        monkeypatch.setenv("BURROW_SECRET", HEX)
        assert main(["probe", "--host", "127.0.0.1", "--port", "1", "--timeout", "1", "--json"]) == 1
        out = json.loads(capsys.readouterr().out)
        assert out["ok"] is False and out["verdict"] == "error"
