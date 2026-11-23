"""
Minimal SMTP email sender.

If SMTP_HOST is not configured (typical in development) nothing is sent; the
message is written to the server log instead so the developer can copy the
reset code from the console.
"""
import logging
import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formataddr

from app.core.config import settings

logger = logging.getLogger(__name__)


def send_email(to_email: str, subject: str, text_body: str, html_body: str | None = None) -> bool:
    """Sends an email (UTF-8, Arabic-safe). Returns True on success. Never raises."""
    if not settings.SMTP_HOST:
        logger.warning(
            "SMTP is not configured (SMTP_HOST is empty) - email NOT sent.\n"
            "To: %s\nSubject: %s\n%s", to_email, subject, text_body,
        )
        return False

    from_email = settings.SMTP_FROM_EMAIL or settings.SMTP_USERNAME
    message = EmailMessage()
    message["Subject"] = subject
    message["From"] = formataddr((settings.SMTP_FROM_NAME, from_email))
    message["To"] = to_email
    message.set_content(text_body, charset="utf-8")
    if html_body:
        message.add_alternative(html_body, subtype="html", charset="utf-8")

    try:
        if settings.SMTP_USE_SSL:
            server = smtplib.SMTP_SSL(
                settings.SMTP_HOST, settings.SMTP_PORT, timeout=20,
                context=ssl.create_default_context(),
            )
        else:
            server = smtplib.SMTP(settings.SMTP_HOST, settings.SMTP_PORT, timeout=20)
        with server:
            if settings.SMTP_USE_TLS and not settings.SMTP_USE_SSL:
                server.starttls(context=ssl.create_default_context())
            if settings.SMTP_USERNAME:
                server.login(settings.SMTP_USERNAME, settings.SMTP_PASSWORD)
            server.send_message(message)
        return True
    except Exception:  # noqa: BLE001 - email failure must never crash the request
        logger.exception("Failed to send email to %s", to_email)
        return False


def send_password_reset_email(to_email: str, full_name: str | None, code: str, expire_minutes: int) -> bool:
    """Sends the Arabic 'reset your password' email containing the 6-digit code."""
    name = full_name or "عزيزي المستخدم"
    subject = "رمز استعادة كلمة المرور - مهارة"
    text_body = (
        f"مرحباً {name}،\n\n"
        "وصلنا طلب لاستعادة كلمة المرور الخاصة بحسابك في تطبيق مهارة.\n"
        f"رمز التحقق الخاص بك هو: {code}\n\n"
        f"هذا الرمز صالح لمدة {expire_minutes} دقيقة فقط.\n"
        "إذا لم تطلب ذلك، تجاهل هذه الرسالة ولن يتغير شيء في حسابك.\n\n"
        "فريق مهارة"
    )
    html_body = f"""\
<div dir="rtl" style="font-family:Tahoma,Arial,sans-serif;max-width:480px;margin:auto;padding:24px;border:1px solid #eee;border-radius:12px;text-align:right">
  <h2 style="color:#6C4DF6;margin:0 0 12px">مهارة</h2>
  <p>مرحباً {name}،</p>
  <p>وصلنا طلب لاستعادة كلمة المرور الخاصة بحسابك. استخدم الرمز التالي داخل التطبيق:</p>
  <div style="font-size:32px;letter-spacing:8px;font-weight:bold;text-align:center;background:#F4F1FF;color:#4B2FD0;border-radius:10px;padding:14px;margin:16px 0" dir="ltr">{code}</div>
  <p>هذا الرمز صالح لمدة {expire_minutes} دقيقة فقط.</p>
  <p style="color:#888;font-size:13px">إذا لم تطلب ذلك، تجاهل هذه الرسالة ولن يتغير شيء في حسابك.</p>
</div>"""
    return send_email(to_email, subject, text_body, html_body)
