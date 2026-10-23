-- ONLY for the network-isolated, empty restore container. Not a live upgrade.
\set ON_ERROR_STOP on
\getenv migrator_password RECOVERY_MIGRATOR_PASSWORD
\getenv app_password RECOVERY_APP_PASSWORD
\getenv reader_password RECOVERY_READER_PASSWORD
CREATE ROLE gym_intel_migrator LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD :'migrator_password';
CREATE ROLE gym_intel_app LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD :'app_password';
CREATE ROLE gym_intel_grafana LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE
  NOREPLICATION NOBYPASSRLS NOINHERIT PASSWORD :'reader_password';
CREATE DATABASE gym_intel_dev OWNER gym_intel_migrator;
SET ROLE gym_intel_migrator;
REVOKE ALL ON DATABASE gym_intel_dev FROM PUBLIC;
GRANT CONNECT ON DATABASE gym_intel_dev TO gym_intel_app, gym_intel_grafana;
RESET ROLE;
