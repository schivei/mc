#!/bin/sh
# Fails if stage0/*.c goes over the line budget (default 3000).
limit="${1:-3000}"
total=$(cat stage0/*.c | wc -l | tr -d ' ')
echo "stage0: $total / $limit lines"
[ "$total" -le "$limit" ]
