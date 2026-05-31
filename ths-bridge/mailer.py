import os
import smtplib
from email.mime.text import MIMEText


class Mailer:
    def __init__(self) -> None:
        self.host = os.getenv("SMTP_HOST", "").strip()
        self.port = int(os.getenv("SMTP_PORT", "587"))
        self.user = os.getenv("SMTP_USER", "").strip()
        self.password = os.getenv("SMTP_PASS", "").strip()
        self.from_addr = os.getenv("SMTP_FROM", self.user)
        self._enabled = bool(self.host and self.user and self.password)

    def send_password_reset_code(self, email: str, code: str) -> None:
        if not self._enabled:
            return

        subject = "FinMate — 密码重置验证码"
        body = (
            f"您好，\n\n"
            f"您的密码重置验证码为：{code}\n\n"
            f"该验证码 10 分钟内有效。如非本人操作，请忽略此邮件。\n\n"
            f"—— FinMate 团队"
        )

        msg = MIMEText(body, "plain", "utf-8")
        msg["Subject"] = subject
        msg["From"] = self.from_addr
        msg["To"] = email

        server = smtplib.SMTP(self.host, self.port, timeout=15)
        server.starttls()
        server.login(self.user, self.password)
        server.send_message(msg)
        server.quit()


mailer = Mailer()
