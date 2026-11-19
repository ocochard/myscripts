#!/bin/sh
# Install configs script on current $HOME
set -eu
cshrc_cfg() {
	if [ -w $1 ]; then
		sed -i '' -e 's/^setenv	EDITOR	vi$/setenv	EDITOR	vim/' $1
		sed -i '' -e 's/^setenv	PAGER	more$/setenv	PAGER	less/' $1
	fi
}

vim_cfg() {
	cp -n vimrc ${HOME}/.vimrc || true
	cp -n vimrc.bepo ${HOME}/.vimrc.bepo || true
	mkdir -p ${HOME}/.vim/autoload/
	fetch -o ~/.vim/autoload/plug.vim https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim
}

# Replace .shrc only while it is still the stock skel copy
shrc_cfg() {
	if [ ! -e $1 ] || cmp -s $1 /usr/share/skel/dot.shrc; then
		cp shrc $1
	fi
}

cshrc_cfg ${HOME}/.cshrc
shrc_cfg ${HOME}/.shrc
cp -n exrc ${HOME}/.exrc || true
cp -n gitconfig ${HOME}/.gitconfig || true
mkdir -p ${HOME}/.ssh || true
cp -n tmux.conf ${HOME}/.tmux.conf || true
vim_cfg
