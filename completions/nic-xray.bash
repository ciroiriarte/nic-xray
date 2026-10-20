# Bash completion for nic-xray.sh
# Source this file or place it in /etc/bash_completion.d/

_nic_xray() {
	local cur prev words cword split
	# -s splits "--opt=value" so values complete in both forms
	_init_completion -s || return

	case "$prev" in
		--output)
			COMPREPLY=($(compgen -W "table csv json dot svg png" -- "$cur"))
			return
			;;
		--filter-link)
			COMPREPLY=($(compgen -W "up down" -- "$cur"))
			return
			;;
		--cluster)
			COMPREPLY=($(compgen -W "bond nic" -- "$cur"))
			return
			;;
		--diagram-out)
			_filedir
			return
			;;
		--separator|--metrics|--watch)
			# Optional values must be attached (--metrics=5); getopt never
			# takes them from the next word, so only stop when split on "="
			$split && return
			;;
	esac

	# No positional arguments exist, so every other word is an option
	if [[ -z "$cur" || "$cur" == -* ]]; then
		local opts="
			-h --help
			-v --version
			-s --separator
			-m --metrics
			-w --watch
			-o --optics
			-p --physical
			-V --virtual
			--lacp
			--vlan
			--bmac
			--all
			--no-color
			--group-bond
			--cluster
			--output
			--filter-link
			--diagram-out
		"
		COMPREPLY=($(compgen -W "$opts" -- "$cur"))
		return
	fi
} &&
	complete -F _nic_xray nic-xray.sh &&
	complete -F _nic_xray ./nic-xray.sh
