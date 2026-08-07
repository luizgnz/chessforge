# syntax=docker/dockerfile:1.7

FROM python:3.12-slim-bookworm AS deps
WORKDIR /build
COPY requirements.txt .
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --prefix=/install -r requirements.txt

FROM python:3.12-slim-bookworm AS runtime
RUN apt-get update \
    && apt-get install -y --no-install-recommends stockfish \
    && rm -rf /var/lib/apt/lists/*
COPY --from=deps /install /usr/local
WORKDIR /app
COPY chessforge/ ./chessforge/
COPY data/sample.pgn ./data/sample.pgn
ENV STOCKFISH_PATH=/usr/games/stockfish \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1
CMD ["python", "-m", "chessforge.analyze", \
     "--source", "/app/data/sample.pgn", \
     "--depth", "10", \
     "--max-games", "1", \
     "--db", "/tmp/chessforge.db"]
