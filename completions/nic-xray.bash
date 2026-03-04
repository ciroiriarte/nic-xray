# Bash completion for nic-xray.sh
# Source this file or place it in /etc/bash_completion.d/

_nic_xray() {
	local cur prev
	_init_completion || return

	case "$prev" in
		--output)
			COMPREPLY=($(compgen -W "table csv json dot svg png" -- "$cur"))
			return
			;;
		--filter-link)
			COMPREPLY=($(compgen -W "up down" -- "$cur"))
			return
			;;
		--diagram-out)
			_filedir
			return
			;;
		--separator|-s)
			# Optional value, no specific completions
			return
			;;
		--metrics|-m|--watch|-w)
			# Optional seconds value, no specific completions
			return
			;;
	esac

	if [[ "$cur" == -* ]]; then
		local opts="
			-h --help
			-v --version
			-s --separator
			-m --metrics
			-w --watch
			-o --optics
			-p --physical
			--lacp
			--vlan
			--bmac
			--all
			--no-color
			--group-bond
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
