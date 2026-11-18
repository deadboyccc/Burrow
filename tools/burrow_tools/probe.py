"""Network probes: look at a burrow proxy the way Telegram and a censor would.

Verdicts:

``proxy``
    The peer completed a FakeTLS handshake that only someone holding the
    secret can produce.
``fronted``
    The peer answered like an ordinary TLS or HTTP server. This is the
    expected result for wrong secrets, replays, stale timestamps and
    scanners.
``closed``
    The peer accepted the TCP connection and dropped it without sending
    anything (for example an IP blocklist or allowlist rejection).
``error``
    Connection refused, timeout, DNS failure, and so on.
"""

from __future__ import annotations

import os
import socket
import ssl
import time
from dataclasses import dataclass, field
from typing import Any

from . import faketls, mtproto
from .obfuscated2 import ObfuscatedStream
from .secret import Secret

PROXY = "proxy"
FRONTED = "fronted"
CLOSED = "closed"
ERROR = "error"


@dataclass
class Result:
    check: str
    verdict: str
    detail: str
    elapsed_ms: float
    data: dict[str, Any] = field(default_factory=dict)

    def as_dict(self) -> dict[str, Any]:
        return {
            "check": self.check,
            "verdict": self.verdict,
            "detail": self.detail,
            "elapsed_ms": round(self.elapsed_ms, 1),
            **self.data,
        }


def _connect(host: str, port: int, timeout: float) -> socket.socket:
    sock = socket.create_connection((host, port), timeout=timeout)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return sock


def _handshake(sock: socket.socket, key: bytes, hello: bytes, client_random: bytes) -> tuple[str, str]:
    try:
        sock.sendall(hello)
        records = faketls.read_server_flight(sock)
    except faketls.ConnectionClosed as exc:
        if exc.received == 0:
            return CLOSED, "connection closed without a response"
        return FRONTED, f"short non-FakeTLS response ({exc})"
    except (ConnectionResetError, BrokenPipeError):
        return CLOSED, "connection reset by peer"
    except faketls.FakeTLSError as exc:
        return FRONTED, str(exc)

    if faketls.is_proxy_flight(key, client_random, records):
        return PROXY, "FakeTLS ServerHello verified with the secret"

    kinds = ",".join(f"{r.type:#04x}" for r in records)
    return FRONTED, f"peer answered as a regular TLS server (records {kinds})"


def faketls_probe(
    host: str,
    port: int,
    secret: Secret,
    *,
    timeout: float = 10.0,
    time_offset: int = 0,
) -> Result:
    """One FakeTLS handshake; ``time_offset`` simulates client clock skew."""
    started = time.perf_counter()
    try:
        with _connect(host, port, timeout) as sock:
            hello, client_random = faketls.build_client_hello(
                secret.key, secret.host, timestamp=int(time.time()) + time_offset
            )
            verdict, detail = _handshake(sock, secret.key, hello, client_random)
    except OSError as exc:
        verdict, detail = ERROR, f"{type(exc).__name__}: {exc}"
    return Result("faketls", verdict, detail, (time.perf_counter() - started) * 1000)


def replay_probe(host: str, port: int, secret: Secret, *, timeout: float = 10.0) -> Result:
    """Send one valid ClientHello twice. The second copy must not be accepted."""
    started = time.perf_counter()
    hello, client_random = faketls.build_client_hello(secret.key, secret.host)
    verdicts = []
    try:
        for _ in range(2):
            with _connect(host, port, timeout) as sock:
                verdicts.append(_handshake(sock, secret.key, hello, client_random)[0])
    except OSError as exc:
        return Result("replay", ERROR, f"{type(exc).__name__}: {exc}", (time.perf_counter() - started) * 1000)

    first, second = verdicts
    data = {"first": first, "second": second}
    elapsed = (time.perf_counter() - started) * 1000
    if first == PROXY and second != PROXY:
        return Result("replay", FRONTED, f"replayed hello was rejected ({second})", elapsed, data)
    if second == PROXY:
        return Result("replay", PROXY, "replayed hello was ACCEPTED: anti-replay is off", elapsed, data)
    return Result("replay", ERROR, f"first handshake did not succeed ({first})", elapsed, data)


def telegram_probe(
    host: str,
    port: int,
    secret: Secret,
    *,
    dc: int = 2,
    timeout: float = 15.0,
) -> Result:
    """Full path: FakeTLS → obfuscated2 → Telegram DC → resPQ back."""
    started = time.perf_counter()
    try:
        with _connect(host, port, timeout) as sock:
            hello, client_random = faketls.build_client_hello(secret.key, secret.host)
            verdict, detail = _handshake(sock, secret.key, hello, client_random)
            if verdict != PROXY:
                return Result("telegram", verdict, detail, (time.perf_counter() - started) * 1000)

            conn = faketls.FakeTLSConnection(sock)
            stream = ObfuscatedStream(secret.key, dc=dc)
            nonce = os.urandom(16)
            request = mtproto.wrap_padded_intermediate(mtproto.build_req_pq_multi(nonce))

            sent = time.perf_counter()
            conn.send(stream.handshake + stream.encrypt(request))
            length = int.from_bytes(stream.decrypt(conn.recv_exact(4)), "little")
            if not 0 < length <= 1 << 20:
                raise mtproto.MTProtoError(f"implausible packet length {length}")
            answer = mtproto.parse_res_pq(stream.decrypt(conn.recv_exact(length)), nonce)
            rtt = (time.perf_counter() - sent) * 1000
    except (OSError, EOFError, faketls.FakeTLSError, mtproto.MTProtoError) as exc:
        return Result("telegram", ERROR, f"{type(exc).__name__}: {exc}", (time.perf_counter() - started) * 1000)

    return Result(
        "telegram",
        PROXY,
        f"Telegram DC{dc} answered resPQ through the proxy (rtt {rtt:.0f} ms)",
        (time.perf_counter() - started) * 1000,
        {"dc": dc, "rtt_ms": round(rtt, 1), "fingerprints": len(answer.fingerprints)},
    )


def https_probe(
    host: str,
    port: int,
    sni: str,
    *,
    path: str = "/",
    cafile: str | None = None,
    insecure: bool = False,
    timeout: float = 10.0,
) -> Result:
    """What a browser or censor sees: a real TLS handshake plus an HTTP GET."""
    started = time.perf_counter()
    context = ssl.create_default_context(cafile=cafile)
    if insecure:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["http/1.1"])

    request = (
        f"GET {path} HTTP/1.1\r\nHost: {sni}\r\n"
        "User-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)\r\n"
        "Accept: text/html,*/*;q=0.8\r\nConnection: close\r\n\r\n"
    ).encode("ascii")

    try:
        with _connect(host, port, timeout) as raw, context.wrap_socket(raw, server_hostname=sni) as tls:
            cert = tls.getpeercert() or {}
            tls_version = tls.version()
            tls.sendall(request)
            response = bytearray()
            while chunk := tls.recv(65536):
                response += chunk
                if len(response) > 4 << 20:
                    break
    except ssl.SSLCertVerificationError as exc:
        return Result(
            "https", ERROR, f"certificate rejected: {exc.verify_message}", (time.perf_counter() - started) * 1000
        )
    except (OSError, ssl.SSLError) as exc:
        return Result("https", ERROR, f"{type(exc).__name__}: {exc}", (time.perf_counter() - started) * 1000)

    head, _, body = bytes(response).partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    parts = status_line.split(" ", 2)
    status = int(parts[1]) if len(parts) > 1 and parts[1].isdigit() else 0
    issuer = dict(item[0] for item in cert.get("issuer", ())) if cert else {}

    return Result(
        "https",
        FRONTED,
        f"{status_line} over {tls_version}",
        (time.perf_counter() - started) * 1000,
        {
            "status": status,
            "tls_version": tls_version,
            "issuer": issuer.get("organizationName") or issuer.get("commonName", ""),
            "body": body.decode("utf-8", "replace"),
        },
    )


def plaintext_probe(host: str, port: int, *, timeout: float = 10.0) -> Result:
    """Send plain HTTP to the TLS port, as lazy scanners do."""
    started = time.perf_counter()
    try:
        with _connect(host, port, timeout) as sock:
            sock.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
            response = bytearray()
            while len(response) < 65536 and (chunk := sock.recv(65536)):
                response += chunk
    except (ConnectionResetError, BrokenPipeError):
        return Result("plaintext", CLOSED, "connection reset", (time.perf_counter() - started) * 1000)
    except OSError as exc:
        return Result("plaintext", ERROR, f"{type(exc).__name__}: {exc}", (time.perf_counter() - started) * 1000)

    if not response:
        return Result("plaintext", CLOSED, "no response", (time.perf_counter() - started) * 1000)
    first_line = bytes(response).split(b"\r\n", 1)[0].decode("latin-1")
    return Result(
        "plaintext",
        FRONTED,
        first_line,
        (time.perf_counter() - started) * 1000,
        {"body": bytes(response).decode("utf-8", "replace")},
    )
