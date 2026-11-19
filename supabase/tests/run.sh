#!/bin/bash
# Runs the migration + RLS tests on a throwaway PostgreSQL database.
# Usage: PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=chatminusis_rls_test
psql -q -d postgres -c "drop database if exists $DB" -c "drop role if exists anon" -c "drop role if exists authenticated" >/dev/null
psql -q -d postgres -c "create database $DB" >/dev/null
psql -q -v ON_ERROR_STOP=1 -d $DB -f tests/supabase_shim.sql >/dev/null
psql -q -v ON_ERROR_STOP=1 -d $DB -f migrations/20261119000000_init.sql >/dev/null
psql -q -v ON_ERROR_STOP=1 -d $DB -f tests/rls_test.sql
