# Bash completion for nic-sweep.sh
# Source this file or place it in /etc/bash_completion.d/

_nic_sweep() {
	local cur prev words cword split
	# -s splits "--opt=value" so values complete in both forms
	_init_completion -s || return

	case "$prev" in
		-f|--inventory|--ship)
			_filedir
			return
			;;
		-o|--output-dir)
			_filedir -d
			return
			;;
		-l|--level)
			COMPREPLY=($(compgen -W "basic deep" -- "$cur"))
			return
			;;
		-J|--jump)
			_known_hosts_real -- "$cur"
			return
			;;
		-s|--site|-u|--user|-p|--parallel|-T|--timeout|-I|--interval|-L|--lookback)
			# Free-form values: nothing to offer
			return
			;;
	esac

	# No positional arguments exist, so every other word is an option
	if [[ -z "$cur" || "$cur" == -* ]]; then
		local opts="
			-h --help
			-v --version
			-f --inventory
			-s --site
			-J --jump
			-u --user
			-p --parallel
			-T --timeout
			-o --output-dir
			-l --level
			-I --interval
			-L --lookback
			--no-xray
			--ship
			--accept-new-hostkeys
			-n --no-color
		"
		COMPREPLY=($(compgen -W "$opts" -- "$cur"))
		return
	fi
} &&
	complete -F _nic_sweep nic-sweep &&
	complete -F _nic_sweep nic-sweep.sh &&
	complete -F _nic_sweep ./nic-sweep.sh
