#!/usr/bin/env python3
"""Minimal HdrHistogram V2 (compressed base64) decoder + percentiles — stdlib only.

Just enough to decode the per-interval `latency_histogram` blobs zrk emits with
--timeseries-histogram, MERGE the windows we care about (they share geometry),
and read percentiles/max back out. Ports the layout/queries from zrk's src/hdr.zig
so a decoded window's percentiles match the scalar percentiles zrk wrote on the
same NDJSON line. Values are microseconds (zrk's recording unit)."""
import base64
import struct
import zlib


class Hdr:
    def __init__(self, lowest, highest, sig_figs):
        self.lowest, self.highest, self.sig_figs = lowest, highest, sig_figs
        self.unit_mag = max(lowest, 1).bit_length() - 1          # floor(log2(lowest))
        largest_single_unit = 2 * 10 ** sig_figs
        scm = (largest_single_unit - 1).bit_length()             # ceil(log2(..))
        self.shcm = scm - 1 if scm > 0 else 0                    # sub_bucket_half_count_magnitude
        self.sub_bucket_count = 1 << (self.shcm + 1)
        self.sub_bucket_half_count = self.sub_bucket_count >> 1
        self.sub_bucket_mask = (self.sub_bucket_count - 1) << self.unit_mag
        self.bucket_count = self._buckets_needed(highest)
        self.counts_len = (self.bucket_count + 1) * self.sub_bucket_half_count
        self.counts = [0] * self.counts_len

    def _buckets_needed(self, value):
        smallest = self.sub_bucket_count << self.unit_mag
        n = 1
        while smallest <= value:
            if smallest > (1 << 63):
                return n + 1
            smallest <<= 1
            n += 1
        return n

    # --- index <-> value math (mirrors hdr.zig) -----------------------------
    def _bucket_index(self, value):
        return (value | self.sub_bucket_mask).bit_length() - self.unit_mag - (self.shcm + 1)

    def _value_from_index(self, index):
        bi = (index >> self.shcm) - 1
        sbi = (index & (self.sub_bucket_half_count - 1)) + self.sub_bucket_half_count
        if bi < 0:
            sbi -= self.sub_bucket_half_count
            bi = 0
        return sbi << (bi + self.unit_mag)

    def _size_of_equiv_range(self, value):
        return 1 << (self._bucket_index(value) + self.unit_mag)

    def _lowest_equiv(self, value):
        bi = self._bucket_index(value)
        return (value >> (bi + self.unit_mag)) << (bi + self.unit_mag)

    def _median_equiv(self, value):
        return self._lowest_equiv(value) + (self._size_of_equiv_range(value) >> 1)

    def _highest_equiv(self, value):
        return self._lowest_equiv(value) + self._size_of_equiv_range(value) - 1

    # --- merge / queries ----------------------------------------------------
    def add(self, other):
        for i, c in enumerate(other.counts):
            if c:
                self.counts[i] += c

    def total(self):
        return sum(self.counts)

    def value_at_percentile(self, p):
        total = self.total()
        if total == 0:
            return 0
        # rank of the percentile; round half AWAY from zero to match zig's @round
        # (Python's round() is banker's rounding and mis-picks the bucket on ties)
        wanted = max(1, int(max(0.0, min(100.0, p)) / 100.0 * total + 0.5))
        running = 0
        for i, c in enumerate(self.counts):
            running += c
            if running >= wanted:
                return self._median_equiv(self._value_from_index(i))
        return self.max()

    def max(self):
        for i in range(self.counts_len - 1, -1, -1):
            if self.counts[i]:
                return self._highest_equiv(self._value_from_index(i))
        return 0


def _read_zigzag(b, pos):
    value = shift = i = 0
    while True:
        byte = b[pos]
        pos += 1
        if i == 8:                       # 9th byte carries the top 8 bits
            value |= byte << 56
            break
        value |= (byte & 0x7f) << shift
        if not (byte & 0x80):
            break
        shift += 7
        i += 1
    return (value >> 1) ^ (-(value & 1)), pos   # zigzag decode


def decode(s):
    """Decode a V2 compressed base64 HdrHistogram string into an `Hdr`."""
    raw = base64.standard_b64decode(s)
    _comp_cookie, zlen = struct.unpack(">II", raw[:8])
    enc = zlib.decompress(raw[8:8 + zlen])
    _cookie, payload_len, _norm, sig_figs = struct.unpack(">IIII", enc[:16])
    lowest, highest, _i2d = struct.unpack(">QQQ", enc[16:40])
    payload = enc[40:40 + payload_len]
    h = Hdr(lowest, highest, sig_figs)
    idx = pos = 0
    while pos < len(payload) and idx < h.counts_len:
        v, pos = _read_zigzag(payload, pos)
        if v < 0:
            idx += -v                    # run of zeros
        else:
            h.counts[idx] = v
            idx += 1
    return h


def merge(blobs):
    """Decode + sum a sequence of base64 blobs (shared geometry). None if empty."""
    acc = None
    for b in blobs:
        h = decode(b)
        if acc is None:
            acc = h
        else:
            acc.add(h)
    return acc
