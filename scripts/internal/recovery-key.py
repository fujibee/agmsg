#!/usr/bin/env python3
"""agmsg recovery key (recovery-key-v1): the human-facing secret a user
copies out of agmsg once and stores in a password manager (or another
offline place they control), used later to reopen their Recovery Vault on
a fresh device (see recovery-vault-format-v1). This module only handles
the key string itself -- generation, canonical display, and strict
parsing/verification -- never the vault envelope or the wrapping crypto
around it.

Format (koit-approved 2026-07-25, superseding an earlier 256-bit design):
  secret  = 15 bytes (120 bits) from a CSPRNG.
  encode  = Crockford Base32 of `secret`, exactly 24 symbols. 120 / 5 = 24
            exactly, so there are no leftover/padding bits -- unlike the
            discarded 256-bit design, where 256 % 5 != 0 forced an awkward
            partial 52nd symbol with its own canonical-bit rule.
  check   = top 5 bits of SHA-256(b"agmsg-recovery-key-check-v1\\0" + secret),
            encoded as a 25th Crockford symbol. Catches transcription
            errors; it is NOT a cryptographic integrity check of anything
            else -- the vault envelope's own AEAD tag does that.
  display = "AGMSG-" + the 25 symbols split into five groups of five,
            joined by "-" (e.g. AGMSG-XXXXX-XXXXX-XXXXX-XXXXX-XXXXX, 35
            characters, one line).

Why 120 bits, and why not the 3-group re-entry confirmation the first
design had: koit's mock review flagged the original 256-bit / re-entry
design as excessive ceremony for an individual user. 128-bit-class
secrets behind an Argon2id-style KDF are the accepted floor for "safe for
life" against offline brute-force. 120 (not 128) because Crockford Base32
needs a bit count that is a clean multiple of 5, and 120 is the nearest
multiple of 5 at or above that floor once a whole number of symbols is
required. (1Password's Secret Key is cited internally only as evidence
this bit strength is an established norm -- user-facing copy must not
name a vendor.)

The parser is tolerant of common transcription noise (surrounding ASCII
whitespace, mixed case, missing/extra hyphens, the Crockford-standard
O/I/L confusable mapping) but never tolerant of a wrong check digit or a
wrong length -- both fail closed.
"""
import hashlib
import re
import secrets
import sys

SECRET_BYTES = 15  # 120 bits
CROCKFORD_ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"  # excludes I, L, O, U
CHECK_DOMAIN = b"agmsg-recovery-key-check-v1\0"
PREFIX = "AGMSG"
GROUP_SIZE = 5
NUM_GROUPS = 5
TOTAL_SYMBOLS = GROUP_SIZE * NUM_GROUPS  # 25 (24 secret + 1 check)
ASCII_WHITESPACE = " \t\n\r\f\v"

# Crockford's standard tolerant-decode mapping for commonly-confused
# characters (O/0, I and L/1). U is not mapped -- it is simply not a
# valid symbol, same as any other character outside the alphabet.
_CONFUSABLE = str.maketrans({"O": "0", "I": "1", "L": "1"})
_SYMBOL_VALUE = {c: i for i, c in enumerate(CROCKFORD_ALPHABET)}


class RecoveryKeyFormatError(ValueError):
    """Raised by parse() on any invalid input. The caller must treat this
    as fail-closed -- never proceed with a partially-parsed secret."""


def _b32_encode_120(secret):
    assert len(secret) == SECRET_BYTES
    bits = int.from_bytes(secret, "big")
    symbols = []
    for i in range(24):
        shift = (23 - i) * 5
        symbols.append(CROCKFORD_ALPHABET[(bits >> shift) & 0x1F])
    return "".join(symbols)


def _b32_decode_120(symbols):
    assert len(symbols) == 24
    bits = 0
    for ch in symbols:
        bits = (bits << 5) | _SYMBOL_VALUE[ch]
    return bits.to_bytes(SECRET_BYTES, "big")


def _check_symbol(secret):
    digest = hashlib.sha256(CHECK_DOMAIN + secret).digest()
    top5 = digest[0] >> 3  # top 5 bits of the first byte
    return CROCKFORD_ALPHABET[top5]


def generate():
    """Return 15 fresh CSPRNG bytes -- the raw secret, not the display form."""
    return secrets.token_bytes(SECRET_BYTES)


def canonical(secret):
    """secret (15 raw bytes) -> canonical 35-char display string."""
    if len(secret) != SECRET_BYTES:
        raise ValueError(f"secret must be exactly {SECRET_BYTES} bytes, got {len(secret)}")
    symbols = _b32_encode_120(secret) + _check_symbol(secret)
    groups = [symbols[i:i + GROUP_SIZE] for i in range(0, TOTAL_SYMBOLS, GROUP_SIZE)]
    return PREFIX + "-" + "-".join(groups)


def parse(raw):
    """Tolerant-but-fail-closed parse of a user-supplied recovery key
    string back to its 15 raw secret bytes. Raises RecoveryKeyFormatError
    with a human-readable reason on any invalid input."""
    if not isinstance(raw, str):
        raise RecoveryKeyFormatError("input must be a string")
    s = raw.strip(ASCII_WHITESPACE).upper()
    s = s.replace("-", "")
    if not s.startswith(PREFIX):
        raise RecoveryKeyFormatError(f"must start with '{PREFIX}'")
    s = s[len(PREFIX):]
    s = s.translate(_CONFUSABLE)
    if len(s) != TOTAL_SYMBOLS:
        raise RecoveryKeyFormatError(
            f"expected {TOTAL_SYMBOLS} symbols after '{PREFIX}' (hyphens ignored), got {len(s)}"
        )
    bad = sorted(set(c for c in s if c not in _SYMBOL_VALUE))
    if bad:
        raise RecoveryKeyFormatError(f"invalid character(s): {''.join(bad)}")
    secret_symbols, check = s[:24], s[24]
    secret = _b32_decode_120(secret_symbols)
    if check != _check_symbol(secret):
        raise RecoveryKeyFormatError("check digit mismatch -- key was mistyped")
    return secret


def _main(argv):
    if len(argv) == 2 and argv[1] == "generate":
        print(canonical(generate()))
        return 0
    if len(argv) == 2 and argv[1] == "verify":
        raw = sys.stdin.readline()
        try:
            secret = parse(raw)
        except RecoveryKeyFormatError as e:
            print(f"agmsg: invalid recovery key: {e}", file=sys.stderr)
            return 1
        print(canonical(secret))
        return 0
    print("usage: recovery-key.py generate|verify", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(_main(sys.argv))
