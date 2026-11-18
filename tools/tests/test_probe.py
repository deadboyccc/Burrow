"""Probe verdicts against small in-process servers that mimic mtg and friends."""

from __future__ import annotations

import contextlib
import socket
import ssl
import subprocess
import threading
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from burrow_tools import faketls, probe
from burrow_tools.secret import Secret

from .mtg_reference import check_client_hello, server_flight

SECRET = Secret(key=bytes(range(16)), host="notes.example.org")


class Server:
    """Accept connections on 127.0.0.1 and hand each one to ``handler``."""

    def __init__(self, handler: Callable[[socket.socket], None]) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(8)
        self.port = self.sock.getsockname()[1]
        self.handler = handler
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self) -> None:
        while True:
            try:
                conn, _ = self.sock.accept()
            except OSError:
                return
            with conn, contextlib.suppress(OSError, ValueError, AssertionError):
                self.handler(conn)

    def close(self) -> None:
        self.sock.close()


def read_hello(conn: socket.socket) -> bytes:
    header = faketls.recv_exact(conn, 5)
    return header + faketls.recv_exact(conn, int.from_bytes(header[3:5], "big"))


def fake_mtg(seen: set[bytes] | None = None) -> Callable[[socket.socket], None]:
    seen = set() if seen is None else seen

    def handler(conn: socket.socket) -> None:
        record = read_hello(conn)
        try:
            hello = check_client_hello(SECRET.key, SECRET.host, record)
        except (ValueError, AssertionError):
            conn.sendall(b"\x15\x03\x03\x00\x02\x02\x28")  # what a real server would say
            return
        if hello["session_id"] in seen:
            conn.sendall(b"\x15\x03\x03\x00\x02\x02\x28")
            return
        seen.add(hello["session_id"])
        conn.sendall(server_flight(SECRET.key, hello))

    return handler


@pytest.fixture
def server(request):
    servers = []

    def start(handler):
        srv = Server(handler)
        servers.append(srv)
        return srv

    yield start
    for srv in servers:
        srv.close()


def test_valid_secret_is_proxy(server):
    srv = server(fake_mtg())
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.PROXY


def test_wrong_secret_is_fronted(server):
    srv = server(fake_mtg())
    other = Secret(key=bytes(16), host=SECRET.host)
    assert probe.faketls_probe("127.0.0.1", srv.port, other).verdict == probe.FRONTED


def test_clock_skew_is_fronted(server):
    srv = server(fake_mtg())
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET, time_offset=3600).verdict == probe.FRONTED


def test_replay_is_detected(server):
    srv = server(fake_mtg())
    result = probe.replay_probe("127.0.0.1", srv.port, SECRET)
    assert result.verdict == probe.FRONTED
    assert result.data == {"first": probe.PROXY, "second": probe.FRONTED}


def test_replay_accepted_is_reported(server):
    always_new: set[bytes] = set()

    def forgetful(conn):
        always_new.clear()
        fake_mtg(always_new)(conn)

    srv = server(forgetful)
    assert probe.replay_probe("127.0.0.1", srv.port, SECRET).verdict == probe.PROXY


def test_immediate_close_is_closed(server):
    srv = server(lambda conn: None)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.CLOSED


def test_regular_tls_flight_is_fronted(server):
    def tls_like(conn):
        read_hello(conn)
        hello = b"\x02\x00\x00\x46\x03\x03" + bytes(70)
        conn.sendall(b"\x16\x03\x03" + len(hello).to_bytes(2, "big") + hello)
        conn.sendall(b"\x14\x03\x03\x00\x01\x01\x17\x03\x03\x00\x04abcd")

    srv = server(tls_like)
    assert probe.faketls_probe("127.0.0.1", srv.port, SECRET).verdict == probe.FRONTED


def test_refused_port_is_error():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        port = sock.getsockname()[1]
    assert probe.faketls_probe("127.0.0.1", port, SECRET, timeout=2).verdict == probe.ERROR


def test_plaintext_probe_reads_http(server):
    def http(conn):
        conn.recv(4096)
        conn.sendall(b"HTTP/1.0 400 Bad Request\r\n\r\nClient sent an HTTP request to an HTTPS server.\n")

    srv = server(http)
    result = probe.plaintext_probe("127.0.0.1", srv.port)
    assert result.verdict == probe.FRONTED
    assert result.detail.startswith("HTTP/1.0 400")


@pytest.fixture(scope="module")
def tls_cert(tmp_path_factory) -> tuple[Path, Path]:
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, SECRET.host)])
    now = datetime.now(UTC)
    cert = (
        x509.CertificateBuilder()
        .subject_name(name)
        .issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - timedelta(minutes=5))
        .not_valid_after(now + timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(SECRET.host)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    directory = tmp_path_factory.mktemp("tls")
    cert_path, key_path = directory / "cert.pem", directory / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption())
    )
    return cert_path, key_path


def https_server(server, cert: Path, key: Path):
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(cert, key)

    def handler(conn):
        with context.wrap_socket(conn, server_side=True) as tls:
            tls.recv(4096)
            tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\nhello notes")

    return server(handler)


def test_https_probe_with_trusted_ca(server, tls_cert):
    srv = https_server(server, *tls_cert)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host, cafile=str(tls_cert[0]))
    assert result.verdict == probe.FRONTED
    assert result.data["status"] == 200
    assert result.data["body"] == "hello notes"


def test_https_probe_rejects_untrusted_cert(server, tls_cert):
    srv = https_server(server, *tls_cert)
    result = probe.https_probe("127.0.0.1", srv.port, SECRET.host)
    assert result.verdict == probe.ERROR
    assert "certificate" in result.detail


def test_https_probe_insecure(server, tls_cert):
    srv = https_server(server, *tls_cert)
    assert probe.https_probe("127.0.0.1", srv.port, SECRET.host, insecure=True).data["status"] == 200


def test_cli_exit_codes(server):
    srv = server(fake_mtg())
    env = {"BURROW_SECRET": SECRET.hex(), "PATH": "/usr/local/bin:/usr/bin:/bin"}
    base = ["python", "-m", "burrow_tools", "probe", "--host", "127.0.0.1", "--port", str(srv.port)]
    assert subprocess.run(base, env=env, check=False, capture_output=True).returncode == 0
    failing = subprocess.run([*base, "--expect", "fronted"], env=env, check=False, capture_output=True)
    assert failing.returncode == 1
    assert b"FAIL faketls: proxy" in failing.stdout
