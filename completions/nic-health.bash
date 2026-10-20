# Bash completion for nic-health.sh
# Source this file or place it in /etc/bash_completion.d/

_nic_health() {
	local cur prev words cword split
	# -s splits "--opt=value" so values complete in both forms
	_init_completion -s || return

	case "$prev" in
		-i|--interface)
			# Interface names from sysfs (no external command)
			local -a IFACES=(/sys/class/net/*)
			IFACES=("${IFACES[@]##*/}")
			COMPREPLY=($(compgen -W "${IFACES[*]}" -- "$cur"))
			return
			;;
		-O|--output)
			COMPREPLY=($(compgen -W "table csv json" -- "$cur"))
			return
			;;
		-l|--level)
			COMPREPLY=($(compgen -W "basic deep" -- "$cur"))
			return
			;;
		-I|--interval)
			# Free-form number of seconds: nothing to offer
			return
			;;
	esac

	# No positional arguments exist, so every other word is an option
	if [[ -z "$cur" || "$cur" == -* ]]; then
		local opts="
			-h --help
			-v --version
			-i --interface
			-I --interval
			-O --output
			-l --level
			-a --all
			-n --no-color
			-t --check-tools
		"
		COMPREPLY=($(compgen -W "$opts" -- "$cur"))
		return
	fi
} &&
	complete -F _nic_health nic-health &&
	complete -F _nic_health nic-health.sh &&
	complete -F _nic_health ./nic-health.sh
