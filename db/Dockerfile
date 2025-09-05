ARG BASE_IMAGE_REF=timescale/timescaledb-ha:pg17
FROM ${BASE_IMAGE_REF}

# Install Python and libs for PL/Python helper functions
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-pip postgresql-plpython3-17 \
 && pip3 install --no-cache-dir \
      boto3==1.34.131 \
      langchain-text-splitters==0.0.2 \
      pymupdf==1.24.4 \
      lxml==5.2.2 \
      python-docx==0.8.11 \
 && rm -rf /var/lib/apt/lists/*

# Ensure plpython3u is available (provided by base image usually)
# Copy initialization scripts
COPY init /docker-entrypoint-initdb.d/

USER postgres
