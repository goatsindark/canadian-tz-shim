#!/usr/bin/env python3
"""
Targeted TZif patcher for canadian-tz-shim (v2 — Canadian/* namespace).

Modifies ONLY:
  * one exact-match entry inside the v1 abbreviation pool (bounded by NULs),
  * one exact-match entry inside the v2 abbreviation pool (bounded by NULs),
  * the leading abbreviation token of the POSIX-TZ footer,
  * optionally a matching DST abbreviation token in the POSIX-TZ footer.

Refuses (exit 1) when the pool does not contain exactly one NUL-bounded
occurrence of `old_abbrev` in a section, or when a match would overlap a
pool entry boundary. This makes the patcher historically safe by
construction: only the *post-transition era's own* pool entry is rewritten,
never a historical abbreviation that happens to share bytes with it.

Usage:
    patch_tzif.py <file> <old_abbrev> <new_abbrev>
        -> on success, prints the number of patched locations on stdout
    patch_tzif.py --validate <file>
        -> validates the file structure, prints nothing, exits 0/1

Both abbreviations must be exactly 3 ASCII characters.
"""

import struct
import sys


class PatchError(RuntimeError):
    pass


def _find_bounded(pool: bytearray, needle: bytes) -> list:
    """Return a list of indices into `pool` where `needle` appears as a
    complete NUL-terminated entry (i.e. a standalone abbreviation).

    A match at index i requires:
      * i == 0 OR pool[i-1] == 0x00, AND
      * pool[i+len(needle)] == 0x00, AND
      * every byte pool[i..i+len(needle)] is printable ASCII (2..6 chars).

    Empty entries are skipped (they never count as a match).
    """
    if len(needle) < 2 or len(needle) > 6:
        raise PatchError("abbreviation length out of pool-entry bounds")
    hits = []
    # Walk entries by splitting on NULs, tracking byte offsets.
    pos = 0
    n = len(pool)
    while pos < n:
        end = pool.find(b"\x00", pos)
        if end == -1:
            end = n
        entry = pool[pos:end]
        if entry == needle:
            hits.append(pos)
        pos = end + 1
    return hits


def _patch_pool(pool: bytearray, old: bytes, new: bytes, label: str) -> int:
    hits = _find_bounded(pool, old)
    if len(hits) > 1:
        raise PatchError(
            f"{label}: found {len(hits)} independent pool entries equal to "
            f"{old!r}; refusing to patch (would rewrite multiple eras).")
    if len(hits) == 0:
        return 0
    idx = hits[0]
    if len(new) != len(old):
        raise PatchError(
            "new abbreviation must be exactly the same length as the old "
            "abbreviation so the pool offsets stay identical")
    pool[idx: idx + len(old)] = new
    return 1


def patch_tzif(filename, old_abbrev, new_abbrev):
    """Patch a TZif file, replacing old_abbrev with new_abbrev in the
    abbreviation pools (v1 and v2) and the POSIX-TZ footer.

    Returns the number of patched locations. Raises PatchError on refusal.
    """
    old_bytes = old_abbrev.encode("ascii")
    new_bytes = new_abbrev.encode("ascii")

    if len(old_bytes) != 3 or len(new_bytes) != 3:
        raise PatchError("abbreviations must be exactly 3 characters")

    with open(filename, "rb") as f:
        data = bytearray(f.read())

    original_size = len(data)
    total_patched = 0

    # Walk the v1 (32-bit) section then the v2 (64-bit) section.
    offset = 0
    posix_start = None
    posix_end = None

    for section in range(2):
        if offset + 44 > len(data):
            break
        if data[offset:offset + 4] != b"TZif":
            break

        counts = struct.unpack(">6I", bytes(data[offset + 20:offset + 44]))
        (tzh_ttisutccount, tzh_ttisstdcount, tzh_leapcount,
         tzh_timecnt, tzh_typecnt, tzh_charcnt) = counts

        time_size = 4 if section == 0 else 8
        leap_size = time_size + 4

        abbrev_offset = (offset + 44
                         + tzh_timecnt * time_size
                         + tzh_timecnt
                         + tzh_typecnt * 6)
        abbrev_end = abbrev_offset + tzh_charcnt
        if abbrev_end > len(data):
            raise PatchError(f"section {section}: abbreviation pool "
                             f"extends past EOF")

        label = "v1 pool" if section == 0 else "v2 pool"
        total_patched += _patch_pool_range(
            data, abbrev_offset, tzh_charcnt, old_bytes, new_bytes, label)

        section_end = (abbrev_end
                       + tzh_leapcount * leap_size
                       + tzh_ttisstdcount
                       + tzh_ttisutccount)

        if section == 1:
            posix_start = section_end
            posix_end = len(data)

        offset = section_end

    # POSIX footer.
    if posix_start is not None and posix_end is not None and posix_end > posix_start:
        pos = posix_start
        if data[pos:pos + 1] == b"\n":
            pos += 1
        # Std-time abbreviation
        if data[pos:pos + 3] == old_bytes:
            data[pos:pos + 3] = new_bytes
            total_patched += 1
            pos += 3
            # Skip offset (digits, optional sign/colon)
            while pos < posix_end and (
                data[pos:pos + 1].isdigit()
                or data[pos:pos + 1] in (b"-", b"+", b":")
            ):
                pos += 1
            # Optional DST abbreviation
            if data[pos:pos + 3] == old_bytes:
                data[pos:pos + 3] = new_bytes
                total_patched += 1

    if len(data) != original_size:
        raise PatchError(f"internal error: size changed "
                         f"{original_size} -> {len(data)}")

    with open(filename, "wb") as f:
        f.write(data)

    return total_patched


def _patch_pool_range(data: bytearray, start: int, length: int,
                      old: bytes, new: bytes, label: str) -> int:
    """Bound the pool walk to data[start:start+length] by working on a
    copy and writing back. This keeps offsets exactly where they were."""
    if length <= 0:
        return 0
    pool = bytearray(data[start:start + length])
    n = _patch_pool(pool, old, new, label)
    if n:
        data[start:start + length] = pool
    return n


def validate_tzif(filename):
    """Validate TZif structure without modifying the file."""
    try:
        with open(filename, "rb") as f:
            data = f.read()
    except OSError:
        return 1

    HEADER_LEN = 44

    def validate_block(data, offset, is_v1):
        if offset + HEADER_LEN > len(data):
            return None
        if data[offset:offset + 4] != b"TZif":
            return None
        try:
            counts = struct.unpack(">6I", bytes(data[offset + 20:offset + 44]))
        except struct.error:
            return None
        ttisut, ttisstd, leapcnt, timecnt, typecnt, charcnt = counts
        if typecnt == 0 or charcnt == 0 or timecnt > 100000:
            return None
        if typecnt > 1000 or charcnt > 100000:
            return None
        tsize = 4 if is_v1 else 8
        lsize = tsize + 4
        transitions = offset + HEADER_LEN
        types = transitions + timecnt * tsize
        ttinfos = types + timecnt
        abbrevs = ttinfos + typecnt * 6
        end = abbrevs + charcnt
        end += leapcnt * lsize
        end += ttisstd + ttisut
        if end > len(data):
            return None
        pool = data[abbrevs:abbrevs + charcnt]
        if b"\x00" not in pool:
            return None
        entries = [e for e in pool.split(b"\x00") if e]
        if not entries:
            return None
        for entry in entries:
            if not (2 <= len(entry) <= 20):
                return None
            if not all(32 <= b < 127 for b in entry):
                return None
        for i in range(timecnt):
            if data[types + i] >= typecnt:
                return None
        return end

    pos = validate_block(data, 0, True)
    if pos is None:
        return 1

    version = data[4:5]
    has_v2 = version in (b"2", b"3", b"4", b"\x3a")

    if has_v2:
        pos2 = validate_block(data, pos, False)
        if pos2 is None:
            return 1
        if pos2 < len(data):
            if data[pos2:pos2 + 1] != b"\n":
                return 1
            nl = data.rfind(b"\n")
            if nl == -1 or nl < pos2:
                return 1
            footer = bytes(data[pos2 + 1:nl]).decode("latin-1").strip()
            if footer and not (2 <= len(footer) <= 100000):
                return 1

    return 0


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--validate":
        sys.exit(validate_tzif(sys.argv[2]))

    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <file> <old_abbrev> <new_abbrev>\n"
              f"       {sys.argv[0]} --validate <file>",
              file=sys.stderr)
        sys.exit(1)

    try:
        result = patch_tzif(sys.argv[1], sys.argv[2], sys.argv[3])
    except PatchError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
    print(result)


if __name__ == "__main__":
    main()
