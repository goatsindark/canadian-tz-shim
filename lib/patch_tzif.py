#!/usr/bin/env python3
"""
Targeted TZif binary patcher for Canadian Timezone Shim.

Patches only TZif abbreviation pools and POSIX footer strings,
leaving transition timestamps, UTC offsets, and all other binary
data untouched.

Usage:
    patch_tzif.py <file> <old_abbrev> <new_abbrev>

Both abbreviations must be exactly 3 ASCII characters.
Prints the number of patched locations to stdout.
Exits 0 on success, 1 on error.
"""

import struct
import sys


def patch_tzif(filename, old_abbrev, new_abbrev):
    """Patch a TZif file, replacing old_abbrev with new_abbrev in abbreviation pools and POSIX footer."""
    old_bytes = old_abbrev.encode("ascii")
    new_bytes = new_abbrev.encode("ascii")

    if len(old_bytes) != 3 or len(new_bytes) != 3:
        print("Error: abbreviations must be exactly 3 characters", file=sys.stderr)
        return -1

    with open(filename, "rb") as f:
        data = bytearray(f.read())

    original_size = len(data)
    total_patched = 0

    def patch_range(data, start, length, old, new):
        """Patch occurrences of old with new within data[start:start+length]."""
        count = 0
        pos = start
        end = min(start + length, len(data))
        while pos < end:
            idx = data.find(old, pos, end)
            if idx == -1:
                break
            data[idx : idx + 3] = new
            count += 1
            pos = idx + 1
        return count

    # Process both v1 (32-bit) and v2 (64-bit) TZif sections
    offset = 0
    posix_start = None
    posix_end = None

    for section in range(2):  # v1 then v2
        if offset + 44 > len(data):
            break

        magic = data[offset : offset + 4]
        if magic != b"TZif":
            break

        version = data[offset + 4 : offset + 5]
        counts = struct.unpack(">6I", bytes(data[offset + 20 : offset + 44]))
        (
            tzh_ttisutccount,
            tzh_ttisstdcount,
            tzh_leapcount,
            tzh_timecnt,
            tzh_typecnt,
            tzh_charcnt,
        ) = counts

        time_size = 4 if section == 0 else 8
        leap_size = time_size + 4

        # Calculate abbreviation pool offset
        # Layout: header(44) + transitions(timecnt*time_size) + types_indices(timecnt)
        #         + ttinfos(typecnt*6) + abbrev_pool(charcnt) + leap_secs(leapcount*leap_size)
        #         + ttisstd(ttisstdcount) + ttisut(ttisutccount)
        abbrev_offset = (
            offset
            + 44
            + (tzh_timecnt * time_size)
            + tzh_timecnt
            + (tzh_typecnt * 6)
        )

        # Patch abbreviation pool
        patched = patch_range(data, abbrev_offset, tzh_charcnt, old_bytes, new_bytes)
        total_patched += patched

        # Calculate end of this section
        section_end = (
            offset
            + 44
            + (tzh_timecnt * time_size)
            + tzh_timecnt
            + (tzh_typecnt * 6)
            + tzh_charcnt
            + (tzh_leapcount * leap_size)
            + tzh_ttisstdcount
            + tzh_ttisutccount
        )

        if section == 1:
            # v2 section end is where POSIX footer starts
            posix_start = section_end
            posix_end = len(data)

        offset = section_end

    # Patch POSIX footer string
    # Format: \nSTD[offset][DST[offset][,rule]]
    # We only want to patch the abbreviation at the start of the POSIX string
    if posix_start is not None and posix_end is not None:
        posix_data = data[posix_start:posix_end]

        # Skip leading newline if present
        posix_offset_in_data = posix_start
        if posix_data.startswith(b'\n'):
            posix_offset_in_data += 1
            posix_data = posix_data[1:]

        # The POSIX string starts with the standard time abbreviation
        if posix_data.startswith(old_bytes):
            data[posix_offset_in_data : posix_offset_in_data + 3] = new_bytes
            total_patched += 1

            # Also check for DST abbreviation after the offset
            # Skip past the standard time offset (digits, possibly with sign)
            pos = 3
            while pos < len(posix_data) and (
                posix_data[pos : pos + 1].isdigit()
                or posix_data[pos : pos + 1] in (b"-", b"+", b":")
            ):
                pos += 1

            # If there's a DST abbreviation, check if it matches old_abbrev
            if pos < len(posix_data):
                dst_candidate = posix_data[pos : pos + 3]
                if dst_candidate == old_bytes:
                    abs_pos = posix_offset_in_data + pos
                    data[abs_pos : abs_pos + 3] = new_bytes
                    total_patched += 1

    # Safety check: file size must be unchanged
    if len(data) != original_size:
        print(
            f"Error: file size changed from {original_size} to {len(data)}",
            file=sys.stderr,
        )
        return -1

    with open(filename, "wb") as f:
        f.write(data)

    return total_patched


def validate_tzif(filename):
    """Validate TZif structure without modifying the file.

    Checks magic bytes, version, header counts, and that every declared
    block fits inside the file. Rejects malformed, truncated, or non-TZif
    input. Returns 0 when valid, 1 otherwise.
    """
    try:
        with open(filename, "rb") as f:
            data = f.read()
    except OSError:
        return 1

    HEADER_LEN = 44
    ABBREV_LEN = 3  # sane minimum abbreviation entry

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

        # Reject implausible header values before doing arithmetic
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

        # leap seconds, std/wall and utc/local indicators follow the pool
        end += leapcnt * lsize
        end += ttisstd + ttisut

        if end > len(data):
            return None  # truncated

        # The abbreviation pool must contain at least one NUL-terminated entry
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

        # Every transition must reference a known local-time type index
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
        # Trailing POSIX-TZ footer (optional), delimited by newlines
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
        print(
            f"Usage: {sys.argv[0]} <file> <old_abbrev> <new_abbrev>\n"
            f"       {sys.argv[0]} --validate <file>",
            file=sys.stderr,
        )
        sys.exit(1)

    filename = sys.argv[1]
    old_abbrev = sys.argv[2]
    new_abbrev = sys.argv[3]

    result = patch_tzif(filename, old_abbrev, new_abbrev)
    if result < 0:
        sys.exit(1)

    print(result)


if __name__ == "__main__":
    main()
