#!/usr/bin/env python3
"""B.1 source profiling: inspect the TAD File GDB before designing the curated schema.

Read-only. Answers the open questions in docs/VALUE_PER_ACRE_SPEC.md Section B:
join coverage, multi-account rates, exempt semantics, numeric parse quality,
acres source choice, and the map-eligibility funnel + VPA distributions that
feed map_stats / MAP_COLOR_MIN / MAX.

Run:
    etl/.venv/bin/python etl/scripts/profile-source.py [--json PATH]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd
import pyogrio

ROOT = Path(__file__).resolve().parents[2]
GDB = ROOT / "data/raw/2025ESRI_Parcels/commondata/2025parcels.gdb"
DEFAULT_JSON = ROOT / "data/processed/source_profile.json"

SQFT_PER_ACRE = 43_560.0

PARCEL_COLS = [
    "TAXPIN",
    "EXEMPTSTATUS",
    "ACRES",
    "CALCULATED_ACREAGE",
    "PARCELTYPE",
    "Shape_Area",
]
PROPERTY_COLS = [
    "Account_Nu",
    "GIS_Link",
    "Property_C",
    "State_Use_",
    "City",
    "Land_Acres",
    "Land_Value",
    "Improvemen",
    "Total_Valu",
    "Appraised_",
]
VALUE_COLS = ["Land_Value", "Improvemen", "Total_Valu", "Appraised_"]

# Collected for the JSON report; printing stays human-shaped.
report: dict = {}


def head(title: str) -> None:
    print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")


def pct(n: float, total: float) -> str:
    return f"{n:,} ({n / total * 100:.2f}%)" if total else f"{n:,} (n/a)"


def to_num(s: pd.Series) -> pd.Series:
    """Cast a TAD string column to numeric the way the ETL will have to.

    Strips $ , and whitespace; blanks and unparseable values become NaN.
    """
    cleaned = (
        s.astype("string")
        .str.strip()
        .str.replace(r"[$,]", "", regex=True)
        .replace({"": pd.NA})
    )
    return pd.to_numeric(cleaned, errors="coerce")


def quantiles(s: pd.Series, qs=(0.01, 0.05, 0.25, 0.5, 0.75, 0.95, 0.99, 0.999)) -> dict:
    s = s.dropna()
    if s.empty:
        return {}
    out = {"min": float(s.min()), "max": float(s.max()), "mean": float(s.mean())}
    out.update({f"p{q * 100:g}": float(s.quantile(q)) for q in qs})
    return out


def print_quantiles(label: str, q: dict) -> None:
    if not q:
        print(f"  {label}: (empty)")
        return
    order = ["min", "p1", "p5", "p25", "p50", "p75", "p95", "p99", "p99.9", "max", "mean"]
    parts = [f"{k}={q[k]:,.1f}" for k in order if k in q]
    print(f"  {label}:\n    " + "  ".join(parts))


# --------------------------------------------------------------------------
# 1. Load
# --------------------------------------------------------------------------
def load() -> tuple[pd.DataFrame, pd.DataFrame]:
    head("1. Source layers")
    if not GDB.is_dir():
        print(f"ERROR: missing File GDB at {GDB}", file=sys.stderr)
        sys.exit(1)

    for name, gtype in pyogrio.list_layers(GDB):
        info = pyogrio.read_info(GDB, layer=name)
        print(f"  {name:<20} {str(gtype or 'table'):<16} features={info['features']:>9,}  crs={info['crs']}")

    print("\nReading attributes (geometry skipped — this is an attribute profile)...")
    parcels = pyogrio.read_dataframe(
        GDB, layer="TADParcels", columns=PARCEL_COLS, read_geometry=False
    )
    prop = pyogrio.read_dataframe(
        GDB, layer="PropertyData", columns=PROPERTY_COLS, read_geometry=False
    )
    print(f"  TADParcels   {len(parcels):>9,} rows x {len(parcels.columns)} cols")
    print(f"  PropertyData {len(prop):>9,} rows x {len(prop.columns)} cols")
    report["counts"] = {"parcels": int(len(parcels)), "property_rows": int(len(prop))}
    return parcels, prop


# --------------------------------------------------------------------------
# 2. Parcel keys and exemption
# --------------------------------------------------------------------------
def profile_parcels(parcels: pd.DataFrame) -> None:
    head("2. TADParcels — key integrity, exemption, parcel type")
    n = len(parcels)

    taxpin = parcels["TAXPIN"].astype("string").str.strip()
    blank = int((taxpin.isna() | (taxpin == "")).sum())
    dupes = int(taxpin.duplicated(keep=False).sum())
    print(f"  TAXPIN blank/null : {pct(blank, n)}")
    print(f"  TAXPIN duplicated : {pct(dupes, n)}  <- parcel grain is NOT unique if > 0")
    if dupes:
        top = taxpin[taxpin.duplicated(keep=False)].value_counts().head(5)
        print("    worst offenders:", ", ".join(f"{k}x{v}" for k, v in top.items()))

    print("\n  EXEMPTSTATUS distinct values:")
    ex = parcels["EXEMPTSTATUS"].astype("string").fillna("<null>").str.strip()
    ex_counts = ex.value_counts(dropna=False)
    for val, cnt in ex_counts.items():
        print(f"    {val!r:<28} {pct(cnt, n)}")

    print("\n  PARCELTYPE distinct values:")
    pt_counts = parcels["PARCELTYPE"].value_counts(dropna=False)
    for val, cnt in pt_counts.head(10).items():
        print(f"    {val!r:<28} {pct(cnt, n)}")

    report["parcels"] = {
        "taxpin_blank": blank,
        "taxpin_duplicated": dupes,
        "exemptstatus": {str(k): int(v) for k, v in ex_counts.items()},
        "parceltype": {str(k): int(v) for k, v in pt_counts.head(20).items()},
    }


# --------------------------------------------------------------------------
# 3. Acres sources
# --------------------------------------------------------------------------
def profile_acres(parcels: pd.DataFrame) -> pd.DataFrame:
    head("3. Acres — which denominator survives contact with the data")
    n = len(parcels)

    calc = pd.to_numeric(parcels["CALCULATED_ACREAGE"], errors="coerce")
    acres_str = to_num(parcels["ACRES"])
    shape_acres = pd.to_numeric(parcels["Shape_Area"], errors="coerce") / SQFT_PER_ACRE

    for label, s in [
        ("CALCULATED_ACREAGE", calc),
        ("ACRES (string)", acres_str),
        ("Shape_Area/43560", shape_acres),
    ]:
        null = int(s.isna().sum())
        zero = int((s == 0).sum())
        neg = int((s < 0).sum())
        usable = int((s > 0).sum())
        print(f"  {label:<20} null={pct(null, n)}  zero={pct(zero, n)}  neg={neg:,}  usable={pct(usable, n)}")

    # Do CALCULATED_ACREAGE and geometry agree? Disagreement means one is stale.
    both = (calc > 0) & (shape_acres > 0)
    if both.any():
        rel = ((calc[both] - shape_acres[both]).abs() / shape_acres[both])
        print(f"\n  CALCULATED_ACREAGE vs Shape_Area agreement (n={int(both.sum()):,}):")
        print(f"    within 1%  : {pct(int((rel <= 0.01).sum()), int(both.sum()))}")
        print(f"    within 5%  : {pct(int((rel <= 0.05).sum()), int(both.sum()))}")
        print(f"    off by >20%: {pct(int((rel > 0.20).sum()), int(both.sum()))}")

    print_quantiles("CALCULATED_ACREAGE distribution (>0)", quantiles(calc[calc > 0]))

    report["acres"] = {
        "calculated_usable": int((calc > 0).sum()),
        "acres_string_usable": int((acres_str > 0).sum()),
        "shape_area_usable": int((shape_acres > 0).sum()),
        "calculated_null_or_zero": int(((calc.isna()) | (calc <= 0)).sum()),
        "calculated_quantiles": quantiles(calc[calc > 0]),
    }

    parcels = parcels.copy()
    parcels["_calc_acres"] = calc
    parcels["_shape_acres"] = shape_acres
    return parcels


# --------------------------------------------------------------------------
# 4. Value fields
# --------------------------------------------------------------------------
def profile_values(prop: pd.DataFrame) -> pd.DataFrame:
    head("4. PropertyData — string value fields, parse quality")
    n = len(prop)
    prop = prop.copy()

    stats = {}
    for col in VALUE_COLS + ["Land_Acres"]:
        raw = prop[col].astype("string").str.strip()
        num = to_num(prop[col])
        blank = int((raw.isna() | (raw == "")).sum())
        unparseable = int((num.isna().sum()) - blank)
        zero = int((num == 0).sum())
        neg = int((num < 0).sum())
        positive = int((num > 0).sum())
        print(
            f"  {col:<12} blank={pct(blank, n):<22} unparseable={unparseable:,}"
            f"  zero={pct(zero, n):<22} neg={neg:,}  positive={pct(positive, n)}"
        )
        if unparseable:
            bad = raw[num.isna() & raw.notna() & (raw != "")].value_counts().head(5)
            print("      sample unparseable:", ", ".join(f"{k!r}x{v}" for k, v in bad.items()))
        prop[f"_{col}"] = num
        stats[col] = {"blank": blank, "unparseable": unparseable, "zero": zero,
                      "negative": neg, "positive": positive}

    # Is Total_Valu just Land + Improvement? Affects whether we store components.
    lv, iv, tv, av = (prop[f"_{c}"] for c in VALUE_COLS)
    both = lv.notna() & iv.notna() & tv.notna()
    if both.any():
        agree = int((((lv + iv) - tv).abs() <= 1)[both].sum())
        print(f"\n  Land + Improvement == Total : {pct(agree, int(both.sum()))} of comparable rows")
    both_ta = tv.notna() & av.notna()
    if both_ta.any():
        agree = int(((tv - av).abs() <= 1)[both_ta].sum())
        print(f"  Total == Appraised          : {pct(agree, int(both_ta.sum()))} of comparable rows")

    print("\n  Classification fields:")
    for col in ["Property_C", "State_Use_", "City"]:
        s = prop[col].astype("string").str.strip()
        nullish = int((s.isna() | (s == "")).sum())
        print(f"    {col:<12} distinct={s.nunique():>6,}  blank={pct(nullish, n)}")
        top = s.value_counts().head(8)
        print("      top:", ", ".join(f"{k}={v:,}" for k, v in top.items()))
        stats[col] = {"distinct": int(s.nunique()), "blank": nullish,
                      "top": {str(k): int(v) for k, v in top.items()}}

    report["property_fields"] = stats
    return prop


# --------------------------------------------------------------------------
# 5. Join coverage / multi-account
# --------------------------------------------------------------------------
def profile_join(parcels: pd.DataFrame, prop: pd.DataFrame) -> pd.DataFrame:
    head("5. Join coverage — TADParcels.TAXPIN = PropertyData.GIS_Link")
    taxpin = parcels["TAXPIN"].astype("string").str.strip()
    link = prop["GIS_Link"].astype("string").str.strip()

    parcel_keys = set(taxpin.dropna()) - {""}
    link_nonblank = link[link.notna() & (link != "")]
    link_keys = set(link_nonblank)

    matched_parcels = len(parcel_keys & link_keys)
    print(f"  parcels with >=1 account   : {pct(matched_parcels, len(parcel_keys))} of {len(parcel_keys):,} distinct TAXPIN")
    print(f"  parcels with no account    : {pct(len(parcel_keys - link_keys), len(parcel_keys))}")
    print(f"  accounts with blank GIS_Link: {pct(int(len(prop) - len(link_nonblank)), len(prop))}")
    orphan = int((~link_nonblank.isin(parcel_keys)).sum())
    print(f"  accounts with no parcel     : {pct(orphan, len(prop))}  <- dropped by the join")

    per_parcel = link_nonblank.value_counts()
    per_parcel = per_parcel[per_parcel.index.isin(parcel_keys)]
    bins = [(1, 1), (2, 2), (3, 5), (6, 10), (11, 50), (51, 10**9)]
    print("\n  accounts per matched parcel:")
    for lo, hi in bins:
        cnt = int(((per_parcel >= lo) & (per_parcel <= hi)).sum())
        label = f"{lo}" if lo == hi else (f"{lo}+" if hi > 10**8 else f"{lo}-{hi}")
        print(f"    {label:<8} {pct(cnt, len(per_parcel))}")
    print(f"    max accounts on one parcel: {int(per_parcel.max()):,}")

    report["join"] = {
        "distinct_taxpin": len(parcel_keys),
        "parcels_with_accounts": matched_parcels,
        "parcels_without_accounts": len(parcel_keys - link_keys),
        "accounts_blank_link": int(len(prop) - len(link_nonblank)),
        "accounts_orphaned": orphan,
        "max_accounts_per_parcel": int(per_parcel.max()),
        "multi_account_parcels": int((per_parcel > 1).sum()),
    }

    # City consistency within a parcel matters: comps key off a single city.
    multi = set(per_parcel[per_parcel > 1].index)
    if multi:
        sub = prop[link.isin(multi)].copy()
        sub["_link"] = link[link.isin(multi)]
        city = sub["City"].astype("string").str.strip()
        sub["_city"] = city
        nun = sub.groupby("_link")["_city"].nunique(dropna=True)
        conflict = int((nun > 1).sum())
        print(f"\n  multi-account parcels with conflicting City: {pct(conflict, len(nun))}")
        report["join"]["city_conflicts"] = conflict

    parcels = parcels.copy()
    parcels["_taxpin"] = taxpin
    prop = prop.copy()
    prop["_link"] = link
    return parcels, prop


# --------------------------------------------------------------------------
# 6. Eligibility funnel + VPA distributions
# --------------------------------------------------------------------------
def profile_funnel(parcels: pd.DataFrame, prop: pd.DataFrame) -> None:
    head("6. Map-eligibility funnel and VPA distributions")

    # Spec rule: sum values across accounts, take acres from the parcel once.
    agg = prop.groupby("_link", dropna=True).agg(
        land_value=("_Land_Value", "sum"),
        total_value=("_Total_Valu", "sum"),
        appraised_value=("_Appraised_", "sum"),
        land_acres=("_Land_Acres", "sum"),
        accounts=("_link", "size"),
        city=("City", "first"),
        property_class=("Property_C", "first"),
    )

    p = parcels.set_index("_taxpin")
    p = p[~p.index.duplicated(keep="first")]
    j = p.join(agg, how="left")
    n = len(j)

    exempt = j["EXEMPTSTATUS"].astype("string").str.strip().str.upper().str.startswith("E").fillna(False)

    steps = []

    def step(label: str, mask: pd.Series) -> pd.Series:
        steps.append((label, int(mask.sum())))
        print(f"  {label:<46} {pct(int(mask.sum()), n)}")
        return mask

    print(f"  {'all parcels':<46} {n:,}")
    m = step("has >=1 matched account", j["accounts"].notna())
    m = step("+ acres > 0 (CALCULATED_ACREAGE)", m & (j["_calc_acres"] > 0))
    m_nonexempt = step("+ non-exempt", m & ~exempt)
    m_land = step("+ land_value > 0", m_nonexempt & (j["land_value"] > 0))
    m_total = step("+ total_value > 0 (instead of land)", m_nonexempt & (j["total_value"] > 0))

    # How much would a Land_Acres fallback rescue?
    rescued = int((j["accounts"].notna() & ~(j["_calc_acres"] > 0) & (j["land_acres"] > 0)).sum())
    print(f"\n  parcels rescued by Land_Acres fallback when CALCULATED_ACREAGE<=0: {rescued:,}")

    # What does excluding exempt actually cost?
    cost = int((m & exempt & (j["land_value"] > 0)).sum())
    print(f"  exempt parcels that DO have land_value>0 (hidden by exclude rule): {pct(cost, n)}")
    ex_val = j.loc[m & exempt, "total_value"].sum()
    all_val = j.loc[m, "total_value"].sum()
    print(f"  share of county total_value sitting on exempt parcels: "
          f"{ex_val / all_val * 100:.2f}%" if all_val else "  (no value)")

    print("\n  VPA distributions over the land-eligible set:")
    acres = j["_calc_acres"]
    vpas = {}
    for name, col in [("land_vpa", "land_value"), ("total_vpa", "total_value"),
                      ("appraised_vpa", "appraised_value")]:
        v = (j[col] / acres)[m_land].replace([np.inf, -np.inf], np.nan)
        vpas[name] = quantiles(v)
        print_quantiles(name, vpas[name])

    cap = 5000.0
    land_vpa = (j["land_value"] / acres)[m_land]
    over = int((land_vpa > cap).sum())
    print(f"\n  land_vpa over the configured cap ({cap:,.0f}): {pct(over, int(m_land.sum()))}"
          "   <- these render black")

    report["funnel"] = {label: cnt for label, cnt in steps}
    report["funnel"]["all_parcels"] = n
    report["funnel"]["rescued_by_land_acres"] = rescued
    report["funnel"]["exempt_with_land_value"] = cost
    report["vpa"] = vpas
    report["over_cap_land_vpa"] = {"cap": cap, "count": over}


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", type=Path, default=DEFAULT_JSON,
                    help=f"write machine-readable report (default: {DEFAULT_JSON})")
    args = ap.parse_args()

    parcels, prop = load()
    profile_parcels(parcels)
    parcels = profile_acres(parcels)
    prop = profile_values(prop)
    parcels, prop = profile_join(parcels, prop)
    profile_funnel(parcels, prop)

    args.json.parent.mkdir(parents=True, exist_ok=True)
    args.json.write_text(json.dumps(report, indent=2, default=float))
    print(f"\nwrote {args.json}")
    print("PROFILE OK")


if __name__ == "__main__":
    main()
