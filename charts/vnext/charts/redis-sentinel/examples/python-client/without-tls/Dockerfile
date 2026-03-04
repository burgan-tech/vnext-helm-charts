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

# Set environment variables (can be overridden at runtime)
ENV SENTINEL_HOSTS="10.1.2.21:26379,10.1.2.22:26379,10.1.2.23:26379" \
    MASTER_NAME="mymaster" \
    REDIS_PASSWORD="1pcIcq5Nf6qecYq2t5hKrCJ65vlb3y7j" \
    SENTINEL_PASSWORD="0z3UczrtguY5SCFwjGhwpZRkfbAxEE2y" \
    USE_TLS="false" \
    KEEP_ALIVE="false"

# Run as non-root user
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app /certs
USER appuser

# Run the application
CMD ["python", "app.py"]

