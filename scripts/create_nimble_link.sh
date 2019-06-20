set -u

if [ `ls -1 *.nimble 2>/dev/null | wc -l ` -gt 0 ]; then
  mkdir -p "$toplevel/${NIMBLE_DIR}/pkgs/${sm_path#*/}-#head"
	PKG_DIR="$(${PWD_CMD})"
	if [ -d src ]; then
    PKG_DIR="${PKG_DIR}/src"
  fi
	echo -e "${PKG_DIR}\n${PKG_DIR}" > "$toplevel/${NIMBLE_DIR}/pkgs/${sm_path#*/}-#head/${sm_path#*/}.nimble-link"
fi

