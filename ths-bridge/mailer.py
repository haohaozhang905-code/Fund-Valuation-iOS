import logging

logger = logging.getLogger("ths-bridge.mailer")


class Mailer:
    def send_password_reset_code(self, email: str, code: str) -> None:
        logger.warning("Password reset code for %s: %s", email, code)


mailer = Mailer()
