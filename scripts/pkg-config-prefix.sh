#!/usr/bin/env bash
set -euo pipefail
output="$(/usr/bin/pkg-config "$@")"
if [[ "$output" != *-I/* && "$output" != *-L/* ]]; then printf '%s\n' "$output"; exit; fi
read -ra flags <<< "$output"
roots=("${P01_DEPS:-$HOME/.cache/ziggurat/webkit-p01-deps}/root" "${GTK_DEPS:-$HOME/.cache/ziggurat/window-state-deps/root}")
for i in "${!flags[@]}"; do
    flag="${flags[i]}"
    if [[ "$flag" == -I/* || "$flag" == -L/* ]]; then
        for root in "${roots[@]}"; do
            if [[ -e "$root${flag:2}" ]]; then flags[i]="${flag:0:2}$root${flag:2}"; break; fi
        done
    fi
done
# Libraries whose .pc uses the default system libdir may omit -L entirely.
printf '%s ' "-L${roots[0]}/usr/lib/x86_64-linux-gnu" "-L${roots[1]}/usr/lib/x86_64-linux-gnu" "${flags[@]}"
printf '\n'
