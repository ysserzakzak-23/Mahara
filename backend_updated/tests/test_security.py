from datetime import datetime, timedelta, timezone

from jose import jwt

from app.core.config import settings
from app.core.security import (
    TokenType,
    _create_token,
    create_access_token,
    create_refresh_token,
    decode_token,
    hash_password,
    verify_password,
)


# -------------------------------------------------------------------- passwords

def test_hash_is_not_the_plain_password():
    assert hash_password("Secret123!") != "Secret123!"


def test_correct_password_verifies():
    assert verify_password("Secret123!", hash_password("Secret123!")) is True


def test_wrong_password_fails():
    assert verify_password("wrong-password", hash_password("Secret123!")) is False


def test_hashing_is_salted():
    assert hash_password("Secret123!") != hash_password("Secret123!")


# ----------------------------------------------------------------------- tokens

def test_access_token_payload():
    payload = decode_token(create_access_token(42))
    assert payload["sub"] == "42"
    assert payload["type"] == TokenType.ACCESS.value


def test_refresh_token_payload():
    payload = decode_token(create_refresh_token(42))
    assert payload["sub"] == "42"
    assert payload["type"] == TokenType.REFRESH.value


def test_refresh_token_outlives_access_token():
    access = decode_token(create_access_token(1))
    refresh = decode_token(create_refresh_token(1))
    assert refresh["exp"] > access["exp"]


def test_access_token_expiry_matches_settings():
    payload = decode_token(create_access_token(1))
    lifetime = payload["exp"] - payload["iat"]
    assert lifetime == settings.ACCESS_TOKEN_EXPIRE_MINUTES * 60


def test_expired_token_is_rejected():
    token = _create_token("1", TokenType.ACCESS, timedelta(seconds=-5))
    assert decode_token(token) is None


def test_token_signed_with_another_secret_is_rejected():
    forged = jwt.encode(
        {"sub": "1", "type": "access", "exp": datetime.now(timezone.utc) + timedelta(hours=1)},
        "some-other-secret",
        algorithm=settings.JWT_ALGORITHM,
    )
    assert decode_token(forged) is None


def test_tampered_token_is_rejected():
    token = create_access_token(1)
    header, payload, signature = token.split(".")
    tampered = ".".join([header, payload, signature[:-2] + ("AA" if not signature.endswith("AA") else "BB")])
    assert decode_token(tampered) is None


def test_garbage_is_rejected():
    assert decode_token("not-a-jwt") is None
    assert decode_token("") is None
