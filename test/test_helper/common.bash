#!/bin/bash
# Shared bats setup/teardown: temp dirs, common loads.

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-file/load'

common_setup() {
    export KPI_TEST_TMPDIR="${BATS_TEST_TMPDIR}/kpi"
    mkdir -p "$KPI_TEST_TMPDIR"
    export HOME="$KPI_TEST_TMPDIR/home"
    mkdir -p "$HOME"
    # Individual modules are sourced directly in each .bats file's own
    # setup(), not here — this only provides shared scaffolding.
}

common_teardown() {
    rm -rf "${KPI_TEST_TMPDIR:?}"
}
