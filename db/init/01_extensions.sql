-- Enable required extensions and create schemas
CREATE SCHEMA IF NOT EXISTS app;

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS plpython3u;
-- pgai core extension (installs into schema ai)
CREATE EXTENSION IF NOT EXISTS ai CASCADE;
