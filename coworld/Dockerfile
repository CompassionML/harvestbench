FROM docker.io/library/python:3.12-slim

# Game and grader share one image. The game calls the hosted Bedrock sidecar
# on behalf of each data-only soul file.
RUN pip install --no-cache-dir \
    fastapi==0.115.5 "uvicorn[standard]==0.34.2" websockets==15.0.1 \
    requests==2.32.3 httpx==0.28.1 pydantic==2.13.5

ENV PYTHONPATH=/app PYTHONUNBUFFERED=1
WORKDIR /app

# the game engine and contact protocol from the benchmark repo, plus the
# Coworld roles. No logs, no transcripts, no keys are copied.
COPY harvest /app/harvest
COPY coworld/__init__.py /app/coworld/__init__.py
COPY coworld/shared /app/coworld/shared
COPY coworld/game /app/coworld/game
COPY coworld/grader /app/coworld/grader

EXPOSE 8080
CMD ["python", "-m", "coworld.game.server"]
