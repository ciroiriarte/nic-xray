# Bash completion for nic-report.py
# Source this file or place it in /etc/bash_completion.d/

_nic_report() {
	# shellcheck disable=SC2034  # _init_completion sets all five; not every one is read
	local cur prev words cword split
	# -s splits "--opt=value" so values complete in both forms
	_init_completion -s || return

	# -C/--compare OLD NEW: both are sweep directories (NEW follows OLD)
	if (( cword >= 2 )) && [[ "${words[cword-2]}" == -C || "${words[cword-2]}" == --compare ]]; then
		_filedir -d
		return
	fi

	case "$prev" in
		-R|--sweep-root|-T|--theme|-C|--compare)
			_filedir -d
			return
			;;
		-o|--output|-A|--ai-brief|-n|--narrative)
			_filedir
			return
			;;
		-U|--audience)
			mapfile -t COMPREPLY < <(compgen -W "engineer management field" -- "$cur")
			return
			;;
		-S|--suppress|-u|--rules)
			_filedir json
			return
			;;
		-O|--output-format)
			mapfile -t COMPREPLY < <(compgen -W "md json html pdf" -- "$cur")
			return
			;;
		-b|--baseline)
			mapfile -t COMPREPLY < <(compgen -W "scope all" -- "$cur")
			return
			;;
		-d|--rx-delta-db|-f|--flap-min|-L|--lldp-lookback)
			return
			;;
		-s|--site)
			# Sites of the --sweep-root given earlier on the line (-R DIR, --sweep-root DIR or --sweep-root=DIR)
			local i root=""
			for (( i = 1; i < cword; i++ )); do
				case "${words[i]}" in
					-R|--sweep-root) root="${words[i+1]}" ;;
					--sweep-root=*) root="${words[i]#--sweep-root=}" ;;
				esac
			done
			if [[ -n "$root" && -d "$root" ]]; then
				local d
				local -a SITES=()
				while IFS= read -r d; do SITES+=("${d##*/}"); done < <(compgen -d -- "$root/")
				mapfile -t COMPREPLY < <(compgen -W "${SITES[*]}" -- "$cur")
			fi
			return
			;;
		-a|--at|-r|--role-regex|-t|--title|-c|--classification)
			# Free-form values: nothing to offer
			return
			;;
		-i|--import)
			# SITE first; paths follow as ordinary words
			return
			;;
	esac

	if [[ "$cur" == -* ]]; then
		local opts="
			-h --help
			-v --version
			-R --sweep-root
			-s --site
			-a --at
			-i --import
			-C --compare
			-r --role-regex
			-b --baseline
			-d --rx-delta-db
			-f --flap-min
			-S --suppress
			-u --rules
			-L --lldp-lookback
			-A --ai-brief
			-U --audience
			-n --narrative
			-N --strict-narrative
			-O --output-format
			-o --output
			-P --per-site
			-T --theme
			-X --strict-theme
			-t --title
			-c --classification
		"
		mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
		return
	fi
	# Positional SWEEP_DIR arguments and --import paths
	_filedir
} &&
	complete -F _nic_report nic-report &&
	complete -F _nic_report nic-report.py &&
	complete -F _nic_report ./nic-report.py
