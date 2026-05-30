from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, EmailStr, Field


Password = Annotated[str, Field(min_length=8, max_length=128)]


class UserOut(BaseModel):
    id: int
    email: str


class AuthResponse(BaseModel):
    accessToken: str
    tokenType: str = "bearer"
    user: UserOut


class AuthRequest(BaseModel):
    email: EmailStr
    password: Password


class PasswordResetRequest(BaseModel):
    email: EmailStr


class PasswordResetConfirmRequest(BaseModel):
    email: EmailStr
    code: Annotated[str, Field(min_length=6, max_length=6)]
    newPassword: Password


class FundPositionIn(BaseModel):
    id: str
    fundCode: Annotated[str, Field(min_length=1, max_length=32)]
    fundName: str = ""
    costPrice: Annotated[float, Field(gt=0)]
    shares: Annotated[float, Field(gt=0)]
    clientUpdatedAt: datetime | None = None


class FundPositionOut(FundPositionIn):
    pass


class StockPositionIn(BaseModel):
    id: str
    symbol: Annotated[str, Field(min_length=1, max_length=15)]
    displayName: str = ""
    averageCost: Annotated[float, Field(gt=0)]
    shares: Annotated[float, Field(gt=0)]
    clientUpdatedAt: datetime | None = None


class StockPositionOut(StockPositionIn):
    pass


class PortfolioIn(BaseModel):
    funds: list[FundPositionIn] = []
    stocks: list[StockPositionIn] = []


class PortfolioOut(BaseModel):
    funds: list[FundPositionOut]
    stocks: list[StockPositionOut]
    updatedAt: datetime

    model_config = ConfigDict(from_attributes=True)
