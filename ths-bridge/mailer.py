import logging
import os
import smtplib
from email.mime.text import MIMEText

logger = logging.getLogger("ths-bridge.mailer")


class Mailer:
    def __init__(self) -> None:
        self.host = os.getenv("SMTP_HOST", "").strip()
        self.port = int(os.getenv("SMTP_PORT", "587"))
        self.user = os.getenv("SMTP_USER", "").strip()
        self.password = os.getenv("SMTP_PASS", "").strip()
        self.from_addr = os.getenv("SMTP_FROM", self.user)
        self._enabled = bool(self.host and self.user and self.password)

        if self._enabled:
            logger.info(
                "SMTP mailer enabled: host=%s port=%d user=%s from=%s",
                self.host, self.port, self.user, self.from_addr,
            )
        else:
            logger.warning(
                "SMTP not configured — set SMTP_HOST/SMTP_USER/SMTP_PASS to enable email sending. "
                "Password reset codes will only appear in server logs."
            )

    def send_password_reset_code(self, email: str, code: str) -> None:
        subject = "FinMate — 密码重置验证码"
        body = (
            f"您好，\n\n"
            f"您的密码重置验证码为：{code}\n\n"
            f"该验证码 10 分钟内有效。如非本人操作，请忽略此邮件。\n\n"
            f"—— FinMate 团队"
        )
        self._send(email, subject, body)

    def _send(self, to: str, subject: str, body: str) -> None:
        # Always log the code so it's visible in dev logs
        logger.warning("Password reset code for %s: visible in email", to)

        if not self._enabled:
            logger.warning("SMTP not configured, email not sent to %s", to)
            return

        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = subject
        msg["From"] = self.from_addr
        msg["To"] = to

        try:
            with smtplib.SMTP(self.host, self.port, timeout=15) as server:
                server.starttls()
                server.login(self.user, self.password)
                server.send_message(msg)
            logger.info("Password reset email sent to %s", to)
        except Exception as e:
            logger.error("Failed to send email to %s: %s", to, e)


mailer = Mailer()
