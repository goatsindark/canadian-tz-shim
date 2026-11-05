#!/usr/bin/env python3
"""Audit patch_tzif.py against fixed historical dates."""
import subprocess, struct, sys, tempfile, os
import datetime as dt
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent   # repo root, one level above tools/
PATCHER = ROOT / "lib" / "patch_tzif.py"
ZONES_CONF = ROOT / "zones.conf"
SYSTEM = Path("/usr/share/zoneinfo")


def parse(path):
    data = path.read_bytes()
    c1 = struct.unpack(">6I", data[20:44])
    v1 = 44 + c1[3]*4 + c1[3] + c1[4]*6 + c1[5] + c1[2]*12 + c1[1] + c1[0]
    off = v1
    c2 = struct.unpack(">6I", data[off+20:off+44])
    ttisut, ttisstd, leap, timecnt, typecnt, charcnt = c2
    trans = struct.unpack(f">{timecnt}q", data[off+44:off+44+timecnt*8])
    tidx_off = off+44+timecnt*8
    tidx = list(data[tidx_off:tidx_off+timecnt])
    ttinfo_off = tidx_off + timecnt
    pool_off = ttinfo_off + typecnt*6
    pool = data[pool_off:pool_off+charcnt]
    def read_abbr(byte_off):
        end = pool.find(b"\x00", byte_off)
        if end == -1: end = len(pool)
        return pool[byte_off:end].decode("latin-1")
    ttinfos = []
    for i in range(typecnt):
        chunk = data[ttinfo_off+i*6: ttinfo_off+(i+1)*6]
        ttinfos.append({
            "utoff": struct.unpack(">i", chunk[0:4])[0],
            "isdst": chunk[4],
            "abbr_off": chunk[5],
            "abbr": read_abbr(chunk[5]),
        })
    footer_start = pool_off + charcnt + leap*12 + ttisstd + ttisut
    if footer_start < len(data) and data[footer_start:footer_start+1] == b"\n":
        end = data.find(b"\n", footer_start+1)
        footer = data[footer_start+1:end].decode("latin-1")
    else:
        footer = ""
    return {"trans": trans, "tidx": tidx, "infos": ttinfos,
            "pool_raw": pool, "footer": footer, "raw": data}


def eras(parsed):
    tt = parsed["trans"]
    ti = parsed["tidx"]
    infos = parsed["infos"]
    init = next((i for i, x in enumerate(infos) if x["isdst"] == 0), 0)
    out = []
    if tt:
        prev_time, prev_i = None, init
        for t, i in zip(tt, ti):
            x = infos[prev_i]
            out.append((prev_time, t, x["utoff"], x["isdst"], x["abbr"]))
            prev_time, prev_i = t, i
        x = infos[prev_i]
        out.append((prev_time, None, x["utoff"], x["isdst"], x["abbr"]))
    else:
        x = infos[init]
        out.append((None, None, x["utoff"], x["isdst"], x["abbr"]))
    return out


def fmt(t):
    if t is None: return "+inf"
    if t < -6e11: return "-inf"
    return dt.datetime.fromtimestamp(t, dt.UTC).strftime("%Y-%m-%d")


def off_str(o):
    s = "-" if o < 0 else "+"
    return f"{s}{abs(o)//3600:02d}:{(abs(o)//60)%60:02d}"


def audit(source, iana_abbr, official_abbr, switchover_year):
    src = SYSTEM / source
    before = parse(src)
    with tempfile.NamedTemporaryFile(delete=False) as f:
        f.write(before["raw"]); tmp = f.name
    subprocess.check_call(
        ["python3", str(PATCHER), tmp, iana_abbr, official_abbr],
        stdout=subprocess.DEVNULL)
    after = parse(Path(tmp))
    os.unlink(tmp)

    ok = True
    if before["trans"] != after["trans"]:
        print("    !! transition timestamps changed"); ok = False
    if [i["utoff"] for i in before["infos"]] != [i["utoff"] for i in after["infos"]]:
        print("    !! offsets changed"); ok = False
    if [i["isdst"] for i in before["infos"]] != [i["isdst"] for i in after["infos"]]:
        print("    !! isdst changed"); ok = False

    # Pool changes
    changes = [(i, b["abbr"], a["abbr"])
               for i, (b, a) in enumerate(zip(before["infos"], after["infos"]))
               if b["abbr"] != a["abbr"]]
    print(f"    ttinfo changes: {changes}")

    print(f"    footer before: {before['footer']!r}")
    print(f"    footer after : {after['footer']!r}")

    # Era timeline — flag any era BEFORE the switchover that changed abbr.
    print("    era timeline (only entries near the switchover shown):")
    b_e = eras(before); a_e = eras(after)
    cutoff = dt.datetime(switchover_year, 1, 1, tzinfo=dt.UTC).timestamp()
    historical_altered = 0
    shown = 0
    for i, (b, a) in enumerate(zip(b_e, a_e)):
        if b[4] != a[4]:
            flag = "  <-- HISTORICAL ALTERED" if (b[0] is None or b[0] < cutoff) else ""
            start_str = fmt(b[0]); end_str = fmt(b[1])
            print(f"      {start_str:>10} → {end_str:>10}  {off_str(b[2])} "
                  f"dst={b[3]}  {b[4]} → {a[4]}{flag}")
            if b[0] is None or b[0] < cutoff:
                historical_altered += 1
            shown += 1
    # Also show the last few unchanged eras for context
    if shown == 0:
        print("      (no abbreviation changes were applied)")
    print(f"    total abbreviations altered: {shown}, historical-altered: {historical_altered}")
    return ok and historical_altered == 0


def main():
    rows = []
    for line in ZONES_CONF.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"): continue
        parts = line.split("|")
        if len(parts) != 5: continue
        rows.append(parts)
    print(f"Auditing {len(rows)} zones against lib/patch_tzif.py\n")
    all_ok = True
    for iana, iana_abbr, official, name, _url in rows:
        print(f"=== {iana}  ({iana_abbr} → {official}) ===")
        ok = audit(iana, iana_abbr, official, 2020 if "Whitehorse" in iana or "Dawson" in iana else 2026)
        all_ok = all_ok and ok
        print()
    print(f"OVERALL: {'PASS' if all_ok else 'FAIL'}")
    sys.exit(0 if all_ok else 1)


if __name__ == "__main__":
    main()
