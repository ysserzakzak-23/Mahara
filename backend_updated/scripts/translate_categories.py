"""
One-time script: renames the service categories stored in the database to Arabic.

Category names live in the database (they are created from the admin panel), so
they cannot be translated from code. This script maps the common English names
to Arabic and prints any category it did not recognise so you can rename it
yourself from the admin panel.

USAGE:
    cd backend
    python -m scripts.translate_categories --dry-run   # preview only
    python -m scripts.translate_categories             # apply

It is safe to run more than once.
"""
import argparse

from sqlalchemy import select

from app.core.database import SessionLocal
from app.models.category import ServiceCategory

from app.utils.category_names import TRANSLATIONS  # noqa: E402


def main(dry_run: bool) -> None:
    db = SessionLocal()
    try:
        categories = db.execute(select(ServiceCategory)).scalars().all()
        existing_names = {c.name for c in categories}
        unknown: list[str] = []
        changed = 0

        for category in categories:
            key = category.name.strip().lower()
            arabic = "أخرى" if category.is_other else TRANSLATIONS.get(key)
            if arabic is None:
                if not any("\u0600" <= ch <= "\u06FF" for ch in category.name):
                    unknown.append(category.name)
                continue
            if arabic == category.name:
                continue
            if arabic in existing_names:
                print(f"! تم تخطي '{category.name}': يوجد تصنيف بالاسم '{arabic}' مسبقاً")
                continue
            print(f"{category.name!r}  ->  {arabic!r}")
            existing_names.discard(category.name)
            existing_names.add(arabic)
            if not dry_run:
                category.name = arabic
            changed += 1

        if not dry_run:
            db.commit()
        print(f"\n{'سيتم تعديل' if dry_run else 'تم تعديل'} {changed} تصنيف.")
        if unknown:
            print("تصنيفات لم يتم التعرف عليها (غيّر أسماءها يدوياً من لوحة الأدمن):")
            for name in unknown:
                print(f"  - {name}")
    finally:
        db.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Translate category names to Arabic")
    parser.add_argument("--dry-run", action="store_true", help="show changes without saving")
    main(parser.parse_args().dry_run)
