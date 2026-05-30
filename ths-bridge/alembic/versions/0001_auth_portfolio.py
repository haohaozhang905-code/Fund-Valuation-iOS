"""auth and portfolio tables

Revision ID: 0001_auth_portfolio
Revises:
Create Date: 2026-05-30
"""

from alembic import op
import sqlalchemy as sa


revision = "0001_auth_portfolio"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "users",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("email_lower", sa.String(length=320), nullable=False),
        sa.Column("password_hash", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("deleted_at", sa.DateTime(timezone=True), nullable=True),
    )
    op.create_index("ix_users_id", "users", ["id"])
    op.create_index("ix_users_email_lower", "users", ["email_lower"], unique=True)

    op.create_table(
        "password_reset_codes",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("code_hash", sa.String(length=255), nullable=False),
        sa.Column("expires_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("used_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("attempt_count", sa.Integer(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
    )
    op.create_index("ix_password_reset_codes_user_id", "password_reset_codes", ["user_id"])

    op.create_table(
        "fund_positions",
        sa.Column("id", sa.String(length=64), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("fund_code", sa.String(length=6), nullable=False),
        sa.Column("fund_name", sa.String(length=255), nullable=False),
        sa.Column("cost_price", sa.Float(), nullable=False),
        sa.Column("shares", sa.Float(), nullable=False),
        sa.Column("client_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "fund_code", name="uq_user_fund_code"),
    )
    op.create_index("ix_fund_positions_user_id", "fund_positions", ["user_id"])

    op.create_table(
        "stock_positions",
        sa.Column("id", sa.String(length=64), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("symbol", sa.String(length=15), nullable=False),
        sa.Column("display_name", sa.String(length=255), nullable=False),
        sa.Column("average_cost", sa.Float(), nullable=False),
        sa.Column("shares", sa.Float(), nullable=False),
        sa.Column("client_updated_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), nullable=False),
        sa.UniqueConstraint("user_id", "symbol", name="uq_user_stock_symbol"),
    )
    op.create_index("ix_stock_positions_user_id", "stock_positions", ["user_id"])


def downgrade() -> None:
    op.drop_index("ix_stock_positions_user_id", table_name="stock_positions")
    op.drop_table("stock_positions")
    op.drop_index("ix_fund_positions_user_id", table_name="fund_positions")
    op.drop_table("fund_positions")
    op.drop_index("ix_password_reset_codes_user_id", table_name="password_reset_codes")
    op.drop_table("password_reset_codes")
    op.drop_index("ix_users_email_lower", table_name="users")
    op.drop_index("ix_users_id", table_name="users")
    op.drop_table("users")
