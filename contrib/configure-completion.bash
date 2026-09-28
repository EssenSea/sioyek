# bash completion for ./configure -- source this file, or install it as
# /usr/share/bash-completion/completions/configure.sioyek, or add:
#   source contrib/configure-completion.bash
_sioyek_configure() {
local cur prev opts names
COMPREPLY=()
cur="${COMP_WORDS[COMP_CWORD]}"
prev="${COMP_WORDS[COMP_CWORD-1]}"

# Directory of this file (repo root, since it lives in contrib/).
local here
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
local parser="$here/cmake/parse-build-options.sh"

# Build the option list from the shared table.
if [ -x "$parser" ]; then
names=$("$parser" --list | cut -d: -f1)
else
names=""
fi
opts="--help --wipe --preset="
for n in $names; do
opts="$opts --enable-$n --disable-$n --with-$n --without-$n"
done

if [[ ${cur} == --preset=* ]]; then
local presets
presets=$(cd "$here" 2>/dev/null && cmake --list-presets 2>/dev/null \
| sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p')
COMPREPLY=($(compgen -W "$presets" -- "${cur#--preset=}"))
return 0
fi

# shellcheck disable=SC2207
COMPREPLY=($(compgen -W "$opts" -- "$cur"))
return 0
}
complete -F _sioyek_configure configure
