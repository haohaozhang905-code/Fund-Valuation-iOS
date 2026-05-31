import os
import smtplib
from email.mime.text import MIMEText


# 使用 uvicorn 的日志系统，确保 Zeabur 能捕获
def _log(msg: str) -> None:
    """通过 uvicorn 日志输出，确保 Zeabur 日志可见"""
    import logging
    logging.getLogger("uvicorn.access").warning("[MAILER] " + msg)


class Mailer:
    def __init__(self) -> None:
        self.host = os.getenv("SMTP_HOST", "").strip()
        self.port = int(os.getenv("SMTP_PORT", "587"))
        self.user = os.getenv("SMTP_USER", "").strip()
        self.password = os.getenv("SMTP_PASS", "").strip()
        self.from_addr = os.getenv("SMTP_FROM", self.user)
        self._enabled = bool(self.host and self.user and self.password)

        if self._enabled:
            _log(f"SMTP configured: host={self.host} port={self.port} user={self.user} from={self.from_addr}")
        else:
            _log("SMTP NOT configured — set SMTP_HOST/SMTP_USER/SMTP_PASS to enable")

    def send_password_reset_code(self, email: str, code: str) -> None:
        _log(f"Sending password reset code to {email}: {code}")

        if not self._enabled:
            _log("SKIPPED: SMTP not configured")
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
            _log(f"Connecting to SMTP {self.host}:{self.port}...")
            with smtplib.SMTP(self.host, self.port, timeout=15) as server:
                server.set_debuglevel(1)
                server.starttls()
                server.login(self.user, self.password)
                server.send_message(msg)
            _log(f"SUCCESS: email sent to {email}")
        except smtplib.SMTPAuthenticationError as e:
            _log(f"AUTH FAILED: code={e.smtp_code} error={e.smtp_error}")
        except smtplib.SMTPConnectError as e:
            _log(f"CONNECT FAILED: {e}")
        except smtplib.SMTPServerDisconnected as e:
            _log(f"DISCONNECTED: {e}")
        except smtplib.SMTPException as e:
            _log(f"SMTP ERROR: {e}")
        except Exception as e:
            _log(f"UNEXPECTED ERROR: {e}")


mailer = Mailer()
