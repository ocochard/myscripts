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

cshrc_cfg ${HOME}/.cshrc
cp -n exrc ${HOME}/.exrc || true
cp -n gitconfig ${HOME}/.gitconfig || true
mkdir -p ${HOME}/.ssh || true
cp -n ssh_rc ${HOME}/.ssh/rc || true
cp -n tmux.conf ${HOME}/.tmux.conf || true
vim_cfg
