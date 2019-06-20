set -u

module_name="${1#*/}"

if [ `ls -1 *.nimble 2>/dev/null | wc -l ` -gt 0 ]; then
  mkdir -p "${NIMBLE_DIR}/pkgs/${module_name}-#head"
	PKG_DIR="$(${PWD_CMD})"
	if [ -d src ]; then
    PKG_DIR="${PKG_DIR}/src"
  fi
	echo -e "${PKG_DIR}\n${PKG_DIR}" > "${NIMBLE_DIR}/pkgs/${module_name}-#head/${module_name}.nimble-link"
fi

