#!/bin/bash

set -eu
trap 'echo "Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)"' ERR

for i in "$@"; do
    [ -f "$i" ] || {
        echo "$i is not a valid file"
        continue
    }
    echo "$i"
    awk '
        BEGIN {
            row_count = 0
            header_count = 0
            key_time = "time"
        }
        /============ Serving Benchmark Result ============/ {
            in_block = 1
            next
        }
        /==================================================/ {
            in_block = 0
            row_count++
            next
        }
        in_block && /:/ && !/^-/ {
            colon_idx = index($0, ":")
            key = substr($0, 1, colon_idx - 1)
            val = substr($0, colon_idx + 1)

            gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (!(key in seen_headers)) {
                seen_headers[key] = 1
                headers_list[header_count++] = key
            }
            data[row_count, key] = val
            next
        }
        /^bench start: [0-9][0-9][0-9][0-9][-:/][0-9][0-9]/ {
            time_val = $0
            sub(/^bench start:[[:space:]]*/, "", time_val)
            data[row_count, key_time] = time_val
            next
        }
        END {
            if (row_count == 0) { exit 0 }
            headers_list[header_count++] = key_time
            for (i = 0; i < header_count; i++) {
                printf "%s%s", (i == 0 ? "" : ","), headers_list[i]
            }
            print ""
            for (r = 0; r < row_count; r++) {
                for (i = 0; i < header_count; i++) {
                    key = headers_list[i]
                    printf "%s%s", (i == 0 ? "" : ","), data[r, key]
                }
                print ""
            }
        }
    ' "$i"
done
