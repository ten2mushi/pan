import yfinance as yf
import numpy as np
import sys
import argparse
import pandas as pd

def fetch_and_preprocess(ticker, period, interval, out_path, start, end):
    print(f"Fetching data for {ticker}...")
    if start and end:
        data = yf.download(ticker, start=start, end=end, interval=interval)
    else:
        data = yf.download(ticker, period=period, interval=interval)
    
    if data.empty:
        print("Error: No data fetched.")
        sys.exit(1)
        
    print(f"Fetched {len(data)} rows.")
    
    # Extract features
    # Sometimes yfinance returns a MultiIndex columns if multiple tickers are passed. We extract the series.
    if isinstance(data.columns, pd.MultiIndex):
        close = data['Close'][ticker].values
        high = data['High'][ticker].values
        low = data['Low'][ticker].values
        open_p = data['Open'][ticker].values
        volume = data['Volume'][ticker].values
    else:
        close = data['Close'].values
        high = data['High'].values
        low = data['Low'].values
        open_p = data['Open'].values
        volume = data['Volume'].values

    # 1. Normalized Price (0 to 1)
    min_p, max_p = np.min(close), np.max(close)
    norm_price = (close - min_p) / (max_p - min_p)
    
    # 2. Normalized Volume (0 to 1), log-scaled to dampen massive spikes and highlight relative changes
    # Add a small epsilon to avoid log(0)
    log_vol = np.log1p(volume)
    min_v, max_v = np.min(log_vol), np.max(log_vol)
    norm_vol = (log_vol - min_v) / (max_v - min_v)
    
    # 3. Volatility (High - Low) normalized (0 to 1)
    volatility = high - low
    min_volat, max_volat = np.min(volatility), np.max(volatility)
    norm_volatility = (volatility - min_volat) / (max_volat - min_volat)
    
    is_up = (close >= open_p).astype(np.float32)
    
    # Interleave into a single float32 array: [price0, vol0, volat0, is_up0, ...]
    out_data = np.zeros(len(data) * 4, dtype=np.float32)
    out_data[0::4] = norm_price.astype(np.float32)
    out_data[1::4] = norm_vol.astype(np.float32)
    out_data[2::4] = norm_volatility.astype(np.float32)
    out_data[3::4] = is_up
    
    out_data.tofile(out_path)
    print(f"Wrote {len(data)} ticks (4 floats per tick) to {out_path}.")
    
    # Also save the dates and prices for the animation
    dates = data.index.strftime('%Y-%m-%d').values
    prices_path = out_path + ".csv"
    
    df = pd.DataFrame({
        "Date": dates,
        "Open": open_p,
        "High": high,
        "Low": low,
        "Close": close,
        "Volume": volume
    })
    df.to_csv(prices_path, index=False)
    print(f"Saved chart data to {prices_path}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ticker", type=str, default="BTC-USD")
    parser.add_argument("--period", type=str, default="2y")
    parser.add_argument("--interval", type=str, default="1d")
    parser.add_argument("--start", type=str, default=None, help="Start date YYYY-MM-DD")
    parser.add_argument("--end", type=str, default=None, help="End date YYYY-MM-DD")
    parser.add_argument("out_path", type=str)
    
    args = parser.parse_args()
    fetch_and_preprocess(args.ticker, args.period, args.interval, args.out_path, args.start, args.end)
