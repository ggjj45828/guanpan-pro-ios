FROM python:3.12-alpine
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 DATA_DIR=/data PORT=8787
WORKDIR /app
COPY server.py /app/server.py
COPY web /app/web
RUN addgroup -S app && adduser -S -G app app && mkdir -p /data && chown -R app:app /app /data
USER app
EXPOSE 8787
VOLUME ["/data"]
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8787/api/ping', timeout=2).read()" || exit 1
CMD ["python", "-u", "/app/server.py"]
