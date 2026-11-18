"""burrow-tools: probes, smoke checks and QR codes for a burrow MTProto proxy.

Everything in here is a *client*. The proxy itself is mtg
(https://github.com/9seconds/mtg); this package only talks to it the same way
a Telegram app or a censor's active prober would, so the tests exercise the
real wire protocol end to end.
"""

__version__ = "1.2.0"
