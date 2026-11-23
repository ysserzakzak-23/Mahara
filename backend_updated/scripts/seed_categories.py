"""
Adds the app's trades (المهن) to the service categories, in Arabic.

The list is the one the smart search understands (`DOMAINS` in
app/utils/arabic_search.py), so a category named "سباكة" and the search for
"بدي أصلح حنفية" speak the same language.

WHAT IT DOES (safe to run more than once)
  * creates every trade that is missing;
  * if you already have the same trade under a similar name ("دهان" for
    "دهان وديكور", "ترجمة" for "ترجمة ولغات"...), it RENAMES that category
    instead of creating a duplicate, so the services already published under
    it keep working;
  * re-activates a category that was switched off;
  * never touches the «أخرى» (catch-all) category - it stays as it is.

USAGE:
    cd backend
    python -m scripts.seed_categories --dry-run   # preview only
    python -m scripts.seed_categories             # apply
"""
import argparse
from dataclasses import dataclass
from typing import Optional

from app.utils.arabic_search import DOMAINS

# Names an older database may already use  ->  the canonical trade name.
ALIASES: dict[str, str] = {
    "دهان": "دهان وديكور",
    "تنسيق حدائق": "حدائق وزراعة",
    "نقل ومواصلات": "نقل وتوصيل",
    "توصيل": "نقل وتوصيل",
    "دروس خصوصية": "تعليم ودروس",
    "تعليم": "تعليم ودروس",
    "برمجة": "برمجة وتطوير",
    "تطوير برمجيات": "برمجة وتطوير",
    "تطوير مواقع": "برمجة وتطوير",
    "دعم تقني": "صيانة حواسيب",
    "تصميم": "تصميم وجرافيك",
    "تصميم جرافيك": "تصميم وجرافيك",
    "ترجمة": "ترجمة ولغات",
    "كتابة": "كتابة وتحرير",
    "تجميل": "تجميل وعناية",
    "مكياج": "تجميل وعناية",
    "حلاقة وتصفيف الشعر": "حلاقة رجالية",
    "طبخ": "طبخ وضيافة",
    "تموين وضيافة": "طبخ وضيافة",
    "ميكانيك": "سيارات",
    "صيانة سيارات": "سيارات",
    "بناء وإنشاءات": "بناء وتشطيب",
    "تبليط": "بناء وتشطيب",
    "لحام": "حدادة وألمنيوم",
    "حدادة": "حدادة وألمنيوم",
    "رعاية الحيوانات الأليفة": "رعاية حيوانات",
    "لياقة بدنية": "رياضة ولياقة",
    "تدريب شخصي": "رياضة ولياقة",
    "صحة": "تمريض وصحة",
    "تدليك": "تمريض وصحة",
    "فعاليات ومناسبات": "مناسبات وأفراح",
    "تنظيم فعاليات": "مناسبات وأفراح",
    "أمن وحراسة": "أمن وأقفال",
    "خدمات قانونية": "خدمات مكتبية وقانونية",
    "محاسبة": "خدمات مكتبية وقانونية",
    "استشارات": "خدمات مكتبية وقانونية",
    "تسويق": "تسويق وإعلان",
    "تكييف": "تكييف وتبريد",
}


@dataclass(frozen=True)
class Existing:
    id: int
    name: str
    is_active: bool = True
    is_other: bool = False


@dataclass(frozen=True)
class Action:
    kind: str                     # "create" | "rename" | "reactivate"
    name: str                     # the canonical name
    category_id: Optional[int] = None
    old_name: Optional[str] = None


def wanted_trades() -> list[str]:
    return list(DOMAINS)


def plan(existing: list[Existing], wanted: Optional[list[str]] = None) -> list[Action]:
    """Pure function: what has to change to have every wanted trade."""
    wanted = wanted if wanted is not None else wanted_trades()
    by_name = {c.name: c for c in existing}
    used_ids: set[int] = set()
    actions: list[Action] = []

    for name in wanted:
        current = by_name.get(name)
        if current is not None:
            used_ids.add(current.id)
            if not current.is_active and not current.is_other:
                actions.append(Action("reactivate", name, current.id))
            continue

        alias = next(
            (
                by_name[old]
                for old, canonical in ALIASES.items()
                if canonical == name
                and old in by_name
                and not by_name[old].is_other
                and by_name[old].id not in used_ids
            ),
            None,
        )
        if alias is not None:
            used_ids.add(alias.id)
            actions.append(Action("rename", name, alias.id, old_name=alias.name))
        else:
            actions.append(Action("create", name))
    return actions


def main(dry_run: bool) -> None:
    from sqlalchemy import select

    from app.core.database import SessionLocal
    from app.models.category import ServiceCategory

    db = SessionLocal()
    try:
        rows = db.execute(select(ServiceCategory)).scalars().all()
        by_id = {row.id: row for row in rows}
        actions = plan([Existing(r.id, r.name, r.is_active, r.is_other) for r in rows])

        for action in actions:
            if action.kind == "create":
                print(f"+ إنشاء: {action.name}")
                if not dry_run:
                    db.add(ServiceCategory(name=action.name, is_active=True, is_other=False))
            elif action.kind == "rename":
                print(f"~ إعادة تسمية: {action.old_name}  ->  {action.name}")
                if not dry_run:
                    by_id[action.category_id].name = action.name
            elif action.kind == "reactivate":
                print(f"* إعادة تفعيل: {action.name}")
                if not dry_run:
                    by_id[action.category_id].is_active = True

        if not dry_run:
            db.commit()
        if not actions:
            print("كل المهن موجودة مسبقاً، لا يوجد شي لتعديله.")
        else:
            verb = "سيتم" if dry_run else "تم"
            print(f"\n{verb} تنفيذ {len(actions)} تغيير.")
    finally:
        db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Add the Arabic trades as service categories")
    parser.add_argument("--dry-run", action="store_true", help="show changes without saving")
    main(parser.parse_args().dry_run)
