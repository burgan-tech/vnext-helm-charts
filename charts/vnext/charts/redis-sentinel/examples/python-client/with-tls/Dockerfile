FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    gcc \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements and install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Create directory for TLS certificates
RUN mkdir -p /certs

# OPTION 1: Copy CA certificate if available in build context
# OPTION 2: Mount as Kubernetes secret at runtime (recommended)
# To build without ca.crt: comment out the line below
COPY ca.crt /certs/ca.crt

# Set environment variables (MUST be overridden at runtime for production)
# These are examples only - DO NOT use in production
ENV SENTINEL_HOSTS="10.1.2.21:26379,10.1.2.22:26379,10.1.2.23:26379" \
    MASTER_NAME="mymaster" \
    REDIS_PASSWORD="" \
    SENTINEL_PASSWORD="" \
    TLS_CA_CERT="/certs/ca.crt" \
    USE_TLS="true" \
    KEEP_ALIVE="false"

# Run as non-root user
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app /certs
USER appuser

# Run the application
CMD ["python", "app.py"]
