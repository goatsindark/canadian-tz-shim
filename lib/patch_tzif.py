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


def main():
    if len(sys.argv) != 4:
        print(f"Usage: {sys.argv[0]} <file> <old_abbrev> <new_abbrev>", file=sys.stderr)
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
