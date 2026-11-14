#!/usr/bin/env python3
"""Ed25519-sign a published catalog file: writes <file>.sig (base64 of the
64-byte signature over the file's exact bytes).

The app (Marracat/Stores/CatalogSignature.swift) checks a downloaded
catalog-v3.json against <file>.sig with the public key built into it, and
keeps its bundled/cached catalog when the signature is missing or wrong
(audit 2026-10-07: the catalog carries every brand's checkout endpoint, so a
tampered file could send checkouts elsewhere).

The private key lives at ~/.config/marracat/catalog-signing.key (raw 32-byte
seed, base64, mode 600) and is never committed. `--init` creates it once and
prints the public key to embed in the app.

On the refresh droplet the key is not this process's to read (2026-11-12):
with MARRACAT_SIGN_SOCKET set, the file is sent to the signer on that socket
(refresh-server/signer/marracat-sign, its own user) and the signature comes
back. Either way a signature is checked against the committed public key,
scripts/catalog-signing.pub, the one built into the app.

  sign_catalog.py FILE [FILE ...]
  sign_catalog.py --verify FILE        # check FILE.sig with the public key
  sign_catalog.py --init               # make the key (refuses to overwrite)
"""
import base64
import os
import socket
import sys
from pathlib import Path

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

KEY = Path(os.environ.get("MARRACAT_CATALOG_KEY", Path.home() / ".config/marracat/catalog-signing.key"))
SOCKET = os.environ.get("MARRACAT_SIGN_SOCKET")
PUBLIC = Path(os.environ.get("MARRACAT_CATALOG_PUB", Path(__file__).with_name("catalog-signing.pub")))


def public_key():
    return Ed25519PublicKey.from_public_bytes(base64.b64decode(PUBLIC.read_text().strip()))


def sign_by_socket(path, sock_path=None, timeout=600):
    """Has the signer sign `path`; writes <path>.sig once it checks out."""
    data = Path(path).read_bytes()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(timeout)
        s.connect(sock_path or SOCKET)
        try:
            s.sendall(f"sign {Path(path).name} {len(data)}\n".encode())
            s.sendall(data)
        except (BrokenPipeError, ConnectionResetError):
            pass   # the signer said no and hung up; its answer is read below
        reply = b""
        while not reply.endswith(b"\n") and len(reply) < 400:
            chunk = s.recv(400)
            if not chunk:
                break
            reply += chunk
    word, _, rest = reply.decode("ascii", "replace").strip().partition(" ")
    if word != "ok":
        sys.exit(f"error: the signer refused {path}: {rest or 'no answer'}")
    public_key().verify(base64.b64decode(rest), data)   # raises InvalidSignature
    Path(str(path) + ".sig").write_text(rest + "\n")


def load_key():
    return Ed25519PrivateKey.from_private_bytes(base64.b64decode(KEY.read_text().strip()))


def public_b64(private):
    raw = private.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def sign(private, path):
    sig = private.sign(Path(path).read_bytes())
    Path(str(path) + ".sig").write_text(base64.b64encode(sig).decode() + "\n")


def verify(public, path):
    sig = base64.b64decode(Path(str(path) + ".sig").read_text().strip())
    public.verify(sig, Path(path).read_bytes())   # raises InvalidSignature


def main(argv):
    if argv[:1] == ["--init"]:
        if KEY.exists():
            sys.exit(f"{KEY} already exists")
        KEY.parent.mkdir(parents=True, exist_ok=True)
        private = Ed25519PrivateKey.generate()
        seed = private.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())
        fd = os.open(KEY, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(base64.b64encode(seed).decode() + "\n")
        print(public_b64(private))
        return
    if argv[:1] == ["--public"]:
        print(public_b64(load_key()))
        return
    if argv[:1] == ["--verify"]:
        public = public_key()
        for p in argv[1:]:
            verify(public, p)
            print(f"{p}: signature ok")
        return
    if not argv:
        sys.exit(__doc__)
    if SOCKET:
        for p in argv:
            sign_by_socket(p)
            print(f"signed {p} (signer)")
        return
    private = load_key()
    public = public_key()
    for p in argv:
        sign(private, p)
        verify(public, p)   # a key that isn't the app's stops here
        print(f"signed {p}")


if __name__ == "__main__":
    main(sys.argv[1:])
