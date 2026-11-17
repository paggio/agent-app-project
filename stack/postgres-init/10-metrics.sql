-- The metrics spoke's two databases and four logins, as infra creates them on dev's RDS.
-- Owned here, not by a product repo, for the reason infra owns them on dev: a database and
-- its roles are the environment's, and the repos only migrate inside them.
-- Runs once, on the first start of an empty volume (docker-entrypoint-initdb.d); the stack
-- forgets everything on down (docs/adr/0011), so that is every `up`.
-- Local passwords equal the role name: they guard nothing reachable.

CREATE ROLE olist_writer LOGIN PASSWORD 'olist_writer';
CREATE ROLE olist_reader LOGIN PASSWORD 'olist_reader';
CREATE ROLE index_writer LOGIN PASSWORD 'index_writer';
CREATE ROLE index_reader LOGIN PASSWORD 'index_reader';

CREATE DATABASE olist OWNER olist_writer;
CREATE DATABASE semantic_index OWNER index_writer;

\connect olist
-- dbt builds as olist_writer, which owns what it creates; the reader gets every table it
-- makes from now on, and nothing else.
ALTER DEFAULT PRIVILEGES FOR ROLE olist_writer GRANT SELECT ON TABLES TO olist_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE olist_writer GRANT USAGE ON SCHEMAS TO olist_reader;
GRANT CONNECT ON DATABASE olist TO olist_reader;
ALTER ROLE olist_reader SET statement_timeout = '30s';

\connect semantic_index
-- The extension needs a superuser here and rds_superuser on dev — the environment's job.
CREATE EXTENSION IF NOT EXISTS vector;
GRANT CONNECT ON DATABASE semantic_index TO index_reader;
-- The indexer migrates as index_writer; what index_reader may do (read the index, insert
-- audit only) is granted by that migration, because it names the tables.
