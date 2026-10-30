FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /opt/wargame/src
COPY src/requirements.txt src/requirements-dev.txt ./
RUN apt-get update && apt-get install -y --no-install-recommends poppler-utils tesseract-ocr tesseract-ocr-eng \
    && rm -rf /var/lib/apt/lists/*
RUN python -m pip install --no-cache-dir -r requirements-dev.txt \
    && useradd --uid 10001 --create-home wargame
COPY --chown=wargame:wargame src/ /opt/wargame/src/
COPY --chown=wargame:wargame docker/ /opt/wargame/docker/
COPY --chown=wargame:wargame web/ /opt/wargame/web/
USER wargame
ENTRYPOINT ["python", "/opt/wargame/docker/manage.py"]
CMD ["help"]
