# Use pkgbase as part of function name

patch_qt4_pkgbuild() {
	# Silence warnings, which produce large amount of
	# log output and Travis CI doesn't like that.
	sed -e 's,|${CXXFLAGS}|,|${CXXFLAGS} -w|,' -i ./PKGBUILD
}
