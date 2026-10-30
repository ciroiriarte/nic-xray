# Bash completion for nic-health.sh
# Source this file or place it in /etc/bash_completion.d/

_nic_health() {
	# shellcheck disable=SC2034  # _init_completion sets all five; not every one is read
	local cur prev words cword split
	# -s splits "--opt=value" so values complete in both forms
	_init_completion -s || return

	case "$prev" in
		-i|--interface)
			# Interface names from sysfs (no external command)
			local -a IFACES=(/sys/class/net/*)
			IFACES=("${IFACES[@]##*/}")
			mapfile -t COMPREPLY < <(compgen -W "${IFACES[*]}" -- "$cur")
			return
			;;
		-O|--output)
			mapfile -t COMPREPLY < <(compgen -W "table csv json" -- "$cur")
			return
			;;
		-l|--level)
			mapfile -t COMPREPLY < <(compgen -W "basic deep" -- "$cur")
			return
			;;
		-I|--interval)
			# Free-form number of seconds: nothing to offer
			return
			;;
		-L|--lookback)
			# Free-form minutes; offer the common windows (0 = off, 1 h, 24 h)
			mapfile -t COMPREPLY < <(compgen -W "0 60 1440" -- "$cur")
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
			-L --lookback
			-O --output
			-l --level
			-a --all
			-n --no-color
			-t --check-tools
		"
		mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
		return
	fi
} &&
	complete -F _nic_health nic-health &&
	complete -F _nic_health nic-health.sh &&
	complete -F _nic_health ./nic-health.sh
