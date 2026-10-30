FROM python:3.12-slim-bookworm
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /opt/giwg/src
COPY src/requirements.txt src/requirements-dev.txt ./
RUN python -m pip install --no-cache-dir -r requirements-dev.txt \
    && useradd --uid 10001 --create-home giwg
COPY --chown=giwg:giwg src/ /opt/giwg/src/
COPY --chown=giwg:giwg docker/ /opt/giwg/docker/
USER giwg
ENTRYPOINT ["python", "/opt/giwg/docker/manage.py"]
CMD ["help"]
