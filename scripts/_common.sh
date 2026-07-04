COMMON_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
REPO_ROOT=$(dirname "$COMMON_DIR")
cd "$REPO_ROOT"

info() { printf "[INFO] %s\n" "$*"; }
die()  { printf "[ERROR] %s\n" "$*" >&2; exit 1; }
