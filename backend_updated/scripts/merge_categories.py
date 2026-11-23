"""
Cleans up OLD categories that duplicate the new trades (المهن).

Typical case: before the trades were added you had a few categories such as
"Plumbing", "Painting" or "تنسيق حدائق"; now the same trade exists twice.
This script MERGES each old category into the trade it duplicates - moving its
services, barter preferences and exchange requests across - and only then
deletes it, so nothing the users created is lost.

(Deleting a category directly in the database is dangerous: its barter
preferences and exchange requests would be deleted with it, and its services
would block the deletion.)

USAGE:
    cd backend
    python -m scripts.seed_categories                  # the 41 trades must exist first
    python -m scripts.merge_categories                 # PREVIEW (changes nothing)
    python -m scripts.merge_categories --apply         # do it
    python -m scripts.merge_categories --apply --delete-unused
    python -m scripts.merge_categories --apply --map "Foo=سباكة" --map "بيبي=رعاية أطفال"

  --map "OLD=NEW"    merge OLD into NEW when the script cannot guess (repeatable)
  --delete-unused    also delete old categories nobody uses and that match nothing
"""
import argparse
from dataclasses import dataclass
from typing import Optional

from app.utils.arabic_search import DOMAINS, normalize
from app.utils.category_names import TRANSLATIONS
from scripts.seed_categories import ALIASES


@dataclass(frozen=True)
class Cat:
    id: int
    name: str
    is_other: bool = False


@dataclass(frozen=True)
class Item:
    legacy: Cat
    target: Optional[str]          # canonical trade name it merges into


def resolve_target(name: str, canonical: set[str], overrides: Optional[dict[str, str]] = None) -> Optional[str]:
    """Which of the new trades does the old category `name` duplicate?"""
    overrides = overrides or {}
    if name in overrides:
        return overrides[name]
    if name in ALIASES:
        return ALIASES[name]
    arabic = TRANSLATIONS.get(name.strip().lower())
    if arabic:
        if arabic in canonical:
            return arabic
        if arabic in ALIASES:
            return ALIASES[arabic]
    wanted = normalize(name)
    for trade in canonical:
        if normalize(trade) == wanted:
            return trade
    return None


def plan(categories: list[Cat], overrides: Optional[dict[str, str]] = None) -> list[Item]:
    """Pure function: the old categories (not a trade, not «أخرى») and where each goes."""
    canonical = set(DOMAINS)
    return [
        Item(c, resolve_target(c.name, canonical, overrides))
        for c in categories
        if c.name not in canonical and not c.is_other
    ]


def parse_maps(values: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        old, sep, new = value.partition("=")
        if not sep or not old.strip() or not new.strip():
            raise SystemExit(f'--map يجب أن يكون بالشكل "القديم=الجديد"، وصلني: {value!r}')
        result[old.strip()] = new.strip()
    return result


def main(apply: bool, delete_unused: bool, overrides: dict[str, str]) -> None:
    from sqlalchemy import delete, func, select, update
    from sqlalchemy.exc import IntegrityError

    from app.core.database import SessionLocal
    from app.models.barter import BarterPreference
    from app.models.category import ServiceCategory
    from app.models.exchange import ExchangeRequest
    from app.models.service import Service

    db = SessionLocal()
    try:
        rows = db.execute(select(ServiceCategory)).scalars().all()
        ids_by_name = {r.id: r.name for r in rows}
        id_of = {r.name: r.id for r in rows}
        items = plan([Cat(r.id, r.name, r.is_other) for r in rows], overrides)

        if not items:
            print("ما في تصنيفات قديمة مكررة، كل شي نظيف.")
            return

        def usage(category_id: int) -> tuple[int, int, int]:
            services = db.scalar(select(func.count()).select_from(Service).where(Service.category_id == category_id)) or 0
            prefs = db.scalar(
                select(func.count()).select_from(BarterPreference).where(
                    (BarterPreference.offered_category_id == category_id)
                    | (BarterPreference.needed_category_id == category_id)
                )
            ) or 0
            requests = db.scalar(
                select(func.count()).select_from(ExchangeRequest).where(
                    (ExchangeRequest.offered_category_id == category_id)
                    | (ExchangeRequest.wanted_category_id == category_id)
                )
            ) or 0
            return services, prefs, requests

        print(f"{'الرقم':<6}{'التصنيف القديم':<28}{'خدمات':<8}{'مقايضة':<8}{'تبادل':<8}يُدمج في")
        for item in items:
            s, p, r = usage(item.legacy.id)
            print(f"{item.legacy.id:<6}{item.legacy.name:<28}{s:<8}{p:<8}{r:<8}{item.target or '-- (غير معروف)'}")

        if not apply:
            print("\nهذه معاينة فقط. أضف --apply للتنفيذ، و --map \"القديم=الجديد\" للتصنيفات غير المعروفة.")
            return

        done = skipped = 0
        for item in items:
            legacy = item.legacy
            s, p, r = usage(legacy.id)
            used = (s + p + r) > 0
            target_id = id_of.get(item.target) if item.target else None

            if item.target and target_id is None:
                print(f"! تخطي '{legacy.name}': المهنة '{item.target}' غير موجودة، شغّل seed_categories أولاً")
                skipped += 1
                continue
            if target_id is None and (used or not delete_unused):
                why = "مستخدم ولا يوجد ما يُدمج فيه" if used else "غير معروف (أضف --delete-unused لحذفه أو --map لدمجه)"
                print(f"! تخطي '{legacy.name}': {why}")
                skipped += 1
                continue

            try:
                if target_id is not None:
                    db.execute(update(Service).where(Service.category_id == legacy.id).values(category_id=target_id))
                    db.execute(update(BarterPreference).where(BarterPreference.offered_category_id == legacy.id).values(offered_category_id=target_id))
                    db.execute(update(BarterPreference).where(BarterPreference.needed_category_id == legacy.id).values(needed_category_id=target_id))
                    db.execute(update(ExchangeRequest).where(ExchangeRequest.offered_category_id == legacy.id).values(offered_category_id=target_id))
                    db.execute(update(ExchangeRequest).where(ExchangeRequest.wanted_category_id == legacy.id).values(wanted_category_id=target_id))
                db.execute(delete(ServiceCategory).where(ServiceCategory.id == legacy.id))
                db.commit()
                print(f"- حُذف '{legacy.name}'" + (f" (دُمج في '{item.target}')" if target_id else ""))
                done += 1
            except IntegrityError:
                db.rollback()
                print(f"! تخطي '{legacy.name}': عند أحد المستخدمين تفضيل مقايضة مماثل للمهنة '{item.target}' مسبقاً، عالجه يدوياً")
                skipped += 1

        print(f"\nتم: {done}، تم تخطي: {skipped}.")
    finally:
        db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Merge old duplicate categories into the new trades")
    parser.add_argument("--apply", action="store_true", help="really merge and delete (default: preview)")
    parser.add_argument("--delete-unused", action="store_true", help="also delete unknown categories nobody uses")
    parser.add_argument("--map", action="append", default=[], metavar="OLD=NEW", help="merge OLD into the trade NEW")
    args = parser.parse_args()
    main(args.apply, args.delete_unused, parse_maps(args.map))
