#!/bin/sh
# Falha se stage0/*.c ultrapassar o orcamento de linhas (default 3000).
limit="${1:-3000}"
total=$(cat stage0/*.c | wc -l | tr -d ' ')
echo "stage0: $total / $limit linhas"
[ "$total" -le "$limit" ]
