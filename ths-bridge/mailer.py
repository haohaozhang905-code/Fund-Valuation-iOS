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

        if self._enabled:
            print(f"[MAILER] SMTP configured: host={self.host} port={self.port} user={self.user} from={self.from_addr}", flush=True)
        else:
            print(f"[MAILER] SMTP NOT configured — set SMTP_HOST/SMTP_USER/SMTP_PASS to enable", flush=True)

    def send_password_reset_code(self, email: str, code: str) -> None:
        print(f"[MAILER] Sending password reset code to {email}: {code}", flush=True)

        if not self._enabled:
            print(f"[MAILER] SKIPPED: SMTP not configured", flush=True)
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

        try:
            print(f"[MAILER] Connecting to SMTP {self.host}:{self.port}...", flush=True)
            with smtplib.SMTP(self.host, self.port, timeout=15) as server:
                server.set_debuglevel(1)  # 打印 SMTP 协议通信细节
                print(f"[MAILER] Starting TLS...", flush=True)
                server.starttls()
                print(f"[MAILER] Logging in as {self.user}...", flush=True)
                server.login(self.user, self.password)
                print(f"[MAILER] Sending email...", flush=True)
                server.send_message(msg)
            print(f"[MAILER] SUCCESS: email sent to {email}", flush=True)
        except smtplib.SMTPAuthenticationError as e:
            print(f"[MAILER] SMTP AUTH FAILED: {e.smtp_code} {e.smtp_error}", flush=True)
        except smtplib.SMTPConnectError as e:
            print(f"[MAILER] SMTP CONNECT FAILED: {e}", flush=True)
        except smtplib.SMTPServerDisconnected as e:
            print(f"[MAILER] SMTP DISCONNECTED: {e}", flush=True)
        except smtplib.SMTPException as e:
            print(f"[MAILER] SMTP ERROR: {e}", flush=True)
        except Exception as e:
            print(f"[MAILER] UNEXPECTED ERROR: {e}", flush=True)


mailer = Mailer()
