"""
One-time CLI script to create or promote an admin account.

WHY THIS IS A SCRIPT, NOT AN API ENDPOINT:
An HTTP endpoint that creates admin accounts would itself need to be
guarded by "is the caller already an admin?" — which is circular for the
very first admin on a fresh database. The standard, secure pattern is a
script run locally by someone with direct database/server access, which
is a fundamentally different trust boundary than "anyone who can reach
the API over the network."

USAGE:
    cd backend
    python -m scripts.create_admin --email admin@example.com --password "SomeStrongPassword123" --name "Platform Admin"

    # To promote an EXISTING user to admin instead of creating a new one:
    python -m scripts.create_admin --email existing-user@example.com --promote-only
"""
import argparse
import sys

from sqlalchemy import select

from app.core.database import SessionLocal
from app.core.security import hash_password
from app.models.profile import UserProfile
from app.models.user import User, UserRole


def create_or_promote_admin(email: str, password: str | None, full_name: str | None, promote_only: bool) -> None:
    db = SessionLocal()
    try:
        existing = db.execute(select(User).where(User.email == email)).scalar_one_or_none()

        if existing is not None:
            if existing.role == UserRole.ADMIN:
                print(f"User '{email}' is already an admin. Nothing to do.")
                return
            existing.role = UserRole.ADMIN
            db.commit()
            print(f"Promoted existing user '{email}' to admin.")
            return

        if promote_only:
            print(f"ERROR: --promote-only was set, but no user with email '{email}' exists.")
            sys.exit(1)

        if not password or not full_name:
            print("ERROR: --password and --name are required when creating a NEW admin user.")
            sys.exit(1)

        if len(password) < 8:
            print("ERROR: --password must be at least 8 characters (same minimum as the public API).")
            sys.exit(1)

        user = User(
            email=email,
            hashed_password=hash_password(password),
            role=UserRole.ADMIN,
        )
        user.profile = UserProfile(full_name=full_name)
        db.add(user)
        db.commit()
        print(f"Created new admin user '{email}'.")
    finally:
        db.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Create or promote an admin account.")
    parser.add_argument("--email", required=True, help="Email address of the admin account")
    parser.add_argument("--password", help="Password for a NEW admin account (required unless --promote-only)")
    parser.add_argument("--name", dest="full_name", help="Full name for a NEW admin account")
    parser.add_argument(
        "--promote-only",
        action="store_true",
        help="Only promote an EXISTING user to admin; do not create a new account",
    )
    args = parser.parse_args()

    create_or_promote_admin(
        email=args.email,
        password=args.password,
        full_name=args.full_name,
        promote_only=args.promote_only,
    )


if __name__ == "__main__":
    main()
