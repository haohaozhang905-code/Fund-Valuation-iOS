"""
thsdk 自动搜码 + 行情查询工具
解决美股前缀不统一（UNQQ/UNYN/UNAM）的问题：
1. 输入 ticker → 自动搜索匹配的 THSCODE
2. 用正确的 THSCODE 查询行情
"""
import time
from typing import Optional
from thsdk import THS


class THSHelper:
    """thsdk 辅助类，自动处理美股代码前缀"""

    def __init__(self):
        self.ths = THS()
        self.ths.__enter__()  # 手动管理连接生命周期时使用

    def close(self):
        self.ths.__exit__(None, None, None)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def resolve_code(self, ticker: str) -> Optional[str]:
        """
        输入 ticker（如 NVDA, NASA, RDW），自动搜索返回正确的 THSCODE。
        返回 None 表示未找到。
        """
        resp = self.ths.search_symbols(ticker)
        time.sleep(0.2)
        if not resp or not resp.data:
            return None
        # 优先匹配 ticker 完全一致的普通股，跳过 ETF/做空/做多等衍生品
        ticker_upper = ticker.upper()
        for item in resp.data:
            code = item.get("THSCODE", "")
            name = item.get("Name", "")
            market = item.get("MarketDisplay", "")
            # 必须是美股
            if market not in ("美股",):
                continue
            # 优先精确匹配普通股代码
            if code.endswith(ticker_upper) and len(code) == len(ticker_upper) + 4:
                # 额外过滤：名称中包含 ticker 或直接匹配，排除做空/做多/ETF
                if "做空" in name or "做多" in name or "ETF" in name.upper():
                    continue
                return code
        # 宽松匹配：取第一个美股结果
        for item in resp.data:
            market = item.get("MarketDisplay", "")
            if market == "美股":
                return item.get("THSCODE")
        return None

    def get_quote(self, ticker: str) -> Optional[dict]:
        """获取股票基础行情，自动解析代码"""
        code = self.resolve_code(ticker)
        if not code:
            return None
        time.sleep(0.2)
        resp = self.ths.market_data_us(code, "基础数据")
        if not resp or resp.df.empty:
            return None
        row = resp.df.iloc[0]
        return {
            "code": code,
            "name": row.get("名称", ""),
            "price": row.get("价格", None),
            "change_pct": row.get("涨跌幅", None),
            "volume": row.get("成交量", None),
            "amount": row.get("成交额", None),
            "open": row.get("今开", None),
            "high": row.get("最高", None),
            "low": row.get("最低", None),
            "prev_close": row.get("昨收", None),
        }

    def batch_quotes(self, tickers: list[str]) -> list[dict]:
        """批量获取多个股票的行情"""
        results = []
        for t in tickers:
            q = self.get_quote(t)
            results.append(q if q else {"ticker": t, "error": "未找到"})
            time.sleep(0.2)
        return results


# ====== 测试 ======
if __name__ == "__main__":
    with THSHelper() as helper:
        tickers = ["NVDA", "MU", "TSM", "INTC", "NASA", "RDW"]
        for t in tickers:
            code = helper.resolve_code(t)
            print(f"{t:6s} -> {code or '未找到'}")
        print()

        quotes = helper.batch_quotes(tickers)
        for q in quotes:
            if "error" in q:
                print(f"{q['ticker']:6s}: {q['error']}")
            else:
                print(f"{q['code']:10s} | {q['name']:10s} | 价格={q['price']} | 涨跌={q['change_pct']}%")