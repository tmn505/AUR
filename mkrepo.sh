#!/usr/bin/env bash

set -e

builduser="${1}"
reposrc="${2}"
alarch="${3}"

reponame=${reposrc##*/}

alchroot=/home/${builduser}/abs/${alarch}
cachedir=/home/${builduser}/cache
pkgdest=/home/${builduser}/repo/${alarch}
srcdest=/home/${builduser}/src

builduseruid=$(id -u ${builduser})
buildusergid=$(id -g ${builduser})

vcssuffix=('bzr' 'cvs' 'darcs' 'git' 'hg' 'svn')

source ${reposrc}/quirks.sh

setup_x86_64_chroot() {
	distro="archlinux"

	local imageinfo imagename mirror

	mirror="https://america.mirror.pkgbuild.com"

	imageinfo="$(wget -q https://www.archlinux.org/iso/latest/sha256sums.txt -O - | grep bootstrap-x86_64)"
	imagename="${imageinfo##* }"

	wget -nc -P ${cachedir}/ "${mirror}/iso/latest/${imagename}"
	tar -x --strip 1 -C ${alchroot}/ -f ${cachedir}/${imagename}
	printf "Server = ${mirror}/\$repo/os/\$arch\n" >> ${alchroot}/etc/pacman.d/mirrorlist
}

# set up-to-date chroot
mkdir -p ${alchroot} ${cachedir}/pkg
mount --bind ${alchroot} ${alchroot}
mount --make-rslave ${alchroot}
setup_${alarch}_chroot

mount -t proc /proc ${alchroot}/proc/
mount --rbind /sys ${alchroot}/sys/
mount --make-rslave ${alchroot}/sys/
mount --rbind /dev ${alchroot}/dev/
mount --make-rslave ${alchroot}/dev/
mount --bind ${cachedir} ${alchroot}/var/cache/pacman
cp -f /etc/resolv.conf ${alchroot}/etc/
printf "en_US.UTF-8 UTF-8\n" > ${alchroot}/etc/locale.gen
chroot ${alchroot} /bin/bash -c \
	"source /etc/profile; \
	pacman-key --init; \
	pacman-key --populate ${distro}; \
	pacman -S -y -u --noconfirm base-devel; \
	locale-gen; \
	groupadd -g ${buildusergid} ${builduser}; \
	useradd -u ${builduseruid} -g ${buildusergid} -m -G wheel -s /bin/bash ${builduser}"
printf "%%wheel ALL=(ALL) NOPASSWD: ALL\n" > ${alchroot}/etc/sudoers.d/wheel

# set up build environment
mkdir -p ${alchroot}/home/${builduser}/${reponame} \
	${alchroot}${pkgdest} \
	${alchroot}${srcdest}
mkdir -p ${pkgdest} ${srcdest}
mount --bind ${pkgdest} ${alchroot}${pkgdest}
mount --bind ${srcdest} ${alchroot}${srcdest}
mount --bind ${reposrc} ${alchroot}/home/${builduser}/${reponame}

sed -e '/DownloadUser/d' -e 's,#DisableSandbox,DisableSandbox,' -i ${alchroot}/etc/pacman.conf
printf "MAKEFLAGS='-j2'\nPACKAGER=\"${reponame} build bot\"\nPKGDEST=${pkgdest}\nSRCDEST=${srcdest}\n" >> ${alchroot}/etc/makepkg.conf

# add local repo where new packagess will be added
if [ ! -f ${alchroot}${pkgdest}/${reponame}.db.tar.gz ]; then
	chroot ${alchroot} /bin/bash -c "repo-add ${pkgdest}/${reponame}.db.tar.gz"
fi
printf "[${reponame}]\nSigLevel = Never TrustAll\nServer = file:///home/${builduser}/repo/\$arch\n" >> ${alchroot}/etc/pacman.conf
cp -f ${alchroot}${pkgdest}/${reponame}.db.tar.gz ${alchroot}/var/lib/pacman/sync/${reponame}.db

# collect all PKGBUILD dirs
allpkgdirs=( $(grep -v -e '^#' -e '=' -e '^$' ${reposrc}/repo-make.conf) )

# download dependencies from AUR specified in repo-make.conf
for d in ${allpkgdirs[@]}; do
	if [ ! -d ${reposrc}/${d} ]; then
		git clone --depth=1 https://aur.archlinux.org/${d##*/}.git ${reposrc}/${d}
	fi
done

# remove packages from repo, not in or commented out in repo-make.conf
allpkgnames=( $(for d in ${allpkgdirs[@]}; do awk '/^pkgname/ {print $3}' ${reposrc}/${d}/.SRCINFO; done) )
allpkgfiles=( $(find ${pkgdest}/ -xtype f -name "*.pkg.tar.*" ! -name "*.sig" ! -name "*-debug-*.pkg.tar.*") )

for fp in ${allpkgfiles[@]}; do
	(fn=${fp##*/}
	if [[ ! "${allpkgnames[@]}" =~ "${fn%-*-*-*.pkg.tar.*}" ]]; then
		chroot ${alchroot} /bin/bash -c "repo-remove ${pkgdest}/${reponame}.db.tar.gz ${fn%-*-*-*.pkg.tar.*}"
		chroot ${alchroot} /bin/bash -c "repo-remove ${pkgdest}/${reponame}-debug.db.tar.gz ${fn%-*-*-*.pkg.tar.*}-debug"
		rm -f ${pkgdest}/${fn%-*-*-*.pkg.tar.*}*
	fi)
done

# make sure builduser owns its stuff
chown -R ${builduseruid}:${buildusergid} ${alchroot}/home/${builduser}/{repo,src,${reponame}}

printf "==> Build packages for ${alarch}\n"
printenv

get_version() {
	local pkgversion pkgepoch

	pkgversion=$(awk '((/^\tpkgver/ && ORS="-") || (/^\tpkgrel/ && ORS=RS)) {print $3}' .SRCINFO)
	pkgepoch=$(awk '/^\tepoch/ {printf $3}' .SRCINFO)

	if [ -z "${pkgepoch}" ]; then
		printf "${pkgversion}"
	else
		printf "${pkgepoch}:${pkgversion}"
	fi
}

# main loop for packages creation and adding them to the repo
for d in ${allpkgdirs[@]}; do
	(if [ -d "${reposrc}/${d}" ]; then
		cd ${reposrc}/${d}

		pkgbase=( $(awk '/^pkgbase/ {print $3}' .SRCINFO) )
		pkgnames=( $(awk '/^pkgname/ {print $3}' .SRCINFO) )
		pkgarch=( $(awk '/^\tarch/ {print $3}' .SRCINFO) )

		# pull latest version for VCS packages
		pkgpos1="${pkgnames[0]}"

		if [[ "${vcssuffix[@]}" =~ "${pkgpos1##*-}" ]]; then
			chroot --userspec=${builduseruid}:${buildusergid} ${alchroot} /bin/bash -c \
				"source /etc/profile; \
				cd /home/${builduser}/${reponame}/${d} && \
				makepkg -o -r -s -A -C --skippgpcheck --needed --noconfirm && \
				makepkg --printsrcinfo > .SRCINFO"
		fi

		pkgversion="$(get_version)"

		if [ ! -f "${pkgdest}/${pkgnames[0]}-${pkgversion}"*.pkg.tar.* ]; then
			printf "==> Building ${pkgnames[*]} ${pkgversion}\n"
			if [[ "${pkgarch[@]}" =~ "${alarch}" ]] || [[ "${pkgarch[@]}" =~ "any" ]]; then
				# apply quirks
				declare -f patch_${d##*/}_pkgbuild &> /dev/null && patch_${d##*/}_pkgbuild

				chroot --userspec=${builduseruid}:${buildusergid} ${alchroot} /bin/bash -c \
					"source /etc/profile; \
					cd /home/${builduser}/${reponame}/${d} && \
					makepkg -c -f -m -r -s --holdver --skippgpcheck --needed --noconfirm"

				# add to repo
				for n in ${pkgnames[@]}; do
					chroot ${alchroot} /bin/bash -c "repo-add -n -R ${pkgdest}/${reponame}.db.tar.gz ${pkgdest}/${n}-${pkgversion}*pkg.tar.*"
				done
				if [[ ! "${pkgarch[@]}" =~ "any" ]]; then
					chroot ${alchroot} /bin/bash -c "repo-add -n -R ${pkgdest}/${reponame}-debug.db.tar.gz ${pkgdest}/${pkgbase}-debug-${pkgversion}*pkg.tar.*"
				fi
				cp -f ${alchroot}${pkgdest}/${reponame}.db.tar.gz ${alchroot}/var/lib/pacman/sync/${reponame}.db

			else
				printf "==> Package not available for ${alarch}, skipping\n"
				true
			fi
		fi
	fi)
done

exit
