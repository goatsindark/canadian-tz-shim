// tz_probe.cpp — fixed-date Qt probe.
// Built on demand by live-kde-verify.sh. Exit 0 on all checks passing.
#include <QByteArray>
#include <QCoreApplication>
#include <QDate>
#include <QDateTime>
#include <QLocale>
#include <QString>
#include <QTimeZone>
#include <QTime>
#include <cstdio>

static void toBuf(const QByteArray &v, QByteArray &out) { out = v; }
static void toBuf(const QString  &v, QByteArray &out) { out = v.toUtf8(); }

static int fail_count = 0;

static void check(const char *id, int y, int mo, int d, int hh,
                  const char *want_abbr, int want_off_h) {
    QDateTime u(QDate(y, mo, d), QTime(hh, 0, 0));
    u.setTimeZone(QTimeZone::utc());
    QTimeZone tz{QByteArray(id)};
    QByteArray ab, idb;
    if (!tz.isValid()) {
        printf("  ✗ %-32s %04d-%02d-%02d  INVALID\n", id, y, mo, d);
        ++fail_count; return;
    }
    toBuf(tz.abbreviation(u), ab);
    toBuf(tz.id(), idb);
    int off = tz.offsetFromUtc(u) / 3600;
    if (ab == want_abbr && off == want_off_h) {
        printf("  ✓ %-32s %04d-%02d-%02d  abbr='%s' off=%+d\n",
               id, y, mo, d, ab.constData(), off);
    } else {
        printf("  ✗ %-32s %04d-%02d-%02d  want=%s/%+d got=%s/%+d\n",
               id, y, mo, d, want_abbr, want_off_h, ab.constData(), off);
        ++fail_count;
    }
}

int main(int argc, char **argv) {
    QCoreApplication app(argc, argv);
    printf("Qt %s\n", qVersion());
    printf("\n=== Fixed-date abbreviation + offset checks ===\n");
    check("Canadian/PCT", 2026, 12, 15, 12, "PCT", -7);
    check("Canadian/PCT", 2027,  6, 15, 12, "PCT", -7);
    check("Canadian/PCT", 2100,  6, 15, 12, "PCT", -7);
    check("Canadian/PCT", 2025,  1, 15, 12, "PST", -8);
    check("Canadian/PCT", 2025,  7, 15, 12, "PDT", -7);
    check("Canadian/ABT", 2026, 12, 15, 12, "ABT", -6);
    check("Canadian/ABT", 2025,  1, 15, 12, "MST", -7);
    check("Canadian/ABT", 2025,  7, 15, 12, "MDT", -6);
    check("Canadian/MBT", 2026, 12, 15, 12, "MBT", -5);
    check("Canadian/MBT", 2025,  1, 15, 12, "CST", -6);
    check("Canadian/MBT", 2025,  7, 15, 12, "CDT", -5);
    check("Canadian/NWT", 2026, 12, 15, 12, "NWT", -6);
    check("Canadian/YST-Whitehorse", 2021, 6, 15, 12, "YST", -7);
    check("Canadian/YST-Dawson",      2021, 6, 15, 12, "YST", -7);

    printf("\n=== systemTimeZone() with /etc/localtime → Canadian/PCT ===\n");
    QByteArray sysid, sysabbr;
    toBuf(QTimeZone::systemTimeZoneId(), sysid);
    QDateTime u(QDate(2026, 12, 15), QTime(12, 0, 0));
    u.setTimeZone(QTimeZone::utc());
    toBuf(QTimeZone::systemTimeZone().abbreviation(u), sysabbr);
    int off = QTimeZone::systemTimeZone().offsetFromUtc(u) / 3600;
    if (sysid == "Canadian/PCT" && sysabbr == "PCT" && off == -7) {
        printf("  ✓ systemTimeZone id='%s' abbr='%s' off=%+d\n",
               sysid.constData(), sysabbr.constData(), off);
    } else {
        printf("  ✗ systemTimeZone id='%s' abbr='%s' off=%+d (expected Canadian/PCT/PCT/-7)\n",
               sysid.constData(), sysabbr.constData(), off);
        ++fail_count;
    }

    printf("\n=== Enumerated in availableTimeZoneIds() ===\n");
    int enumerated = 0;
    for (const auto &z : QTimeZone::availableTimeZoneIds()) {
        if (z == "Canadian/PCT") { ++enumerated; break; }
    }
    if (enumerated) {
        printf("  ✓ Canadian/PCT enumerated\n");
    } else {
        printf("  ✗ Canadian/PCT not in availableTimeZoneIds()\n");
        ++fail_count;
    }

    // Cross-check: source American/Vancouver must still resolve to MST (proving
    // we did NOT modify the official file).
    printf("\n=== IANA source unchanged (regression guard) ===\n");
    QTimeZone src{QByteArray("America/Vancouver")};
    QByteArray src_abbr;
    toBuf(src.abbreviation(u), src_abbr);
    if (src_abbr == "MST") {
        printf("  ✓ America/Vancouver still resolves to MST (source untouched)\n");
    } else {
        printf("  ✗ America/Vancouver resolves to '%s' — source was modified!\n",
               src_abbr.constData());
        ++fail_count;
    }

    // The signal that actually decides whether KDE's digital clock displays
    // "not set": Qt populates country()/comment() from zone.tab. Confirm
    // our custom identifier now has Canada country + a real comment, i.e.
    // the shim's tab registration succeeded.
    printf("\n=== zone.tab registration (KDE blocker signal) ===\n");
    QTimeZone pct{QByteArray("Canadian/PCT")};
    QLocale::Country ctry = pct.country();
    QByteArray cmt = pct.comment().toUtf8();
    bool has_country = (ctry == QLocale::Canada);
    bool has_comment = !cmt.isEmpty() && cmt.contains("PCT");
    if (has_country) {
        printf("  ✓ Canadian/PCT country() = Canada (map marker + valid-zone signal)\n");
    } else {
        printf("  ✗ Canadian/PCT country() = %s (KDE will show 'time zone is not set')\n",
               QLocale::countryToString(ctry).constData());
        ++fail_count;
    }
    if (has_comment) {
        printf("  ✓ Canadian/PCT comment()  = '%s'\n", cmt.constData());
    } else {
        printf("  ✗ Canadian/PCT comment()  = '%s' (expected non-empty starting with 'PCT')\n",
               cmt.constData());
        ++fail_count;
    }

    printf("\nTotal failures: %d\n", fail_count);
    return fail_count == 0 ? 0 : 1;
}
