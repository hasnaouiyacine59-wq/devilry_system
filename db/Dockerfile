FROM postgres:15-alpine

# Install additional tools
RUN apk add --no-cache \
    bash \
    curl \
    postgresql-client \
    tzdata \
    && rm -rf /var/cache/apk/*

# Set timezone
ENV TZ=UTC

# Copy initialization scripts
COPY init.sql /docker-entrypoint-initdb.d/
COPY backup.sh /usr/local/bin/backup.sh

# Make backup script executable
RUN chmod +x /usr/local/bin/backup.sh

# Create backup directory
RUN mkdir -p /backups && chown postgres:postgres /backups

# Health check user
USER postgres
RUN echo "CREATE USER healthcheck WITH PASSWORD 'healthcheck_pass';" | psql

# Expose port
EXPOSE 5432

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB} || exit 1

# Run as postgres user
USER postgres