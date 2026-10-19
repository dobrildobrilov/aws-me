# Source from ~/.bashrc; do not execute as a standalone script.
# Requires: bash, aws CLI v2, jq, awk, GNU date.

_aws_me_profiles() {
	local config="${AWS_CONFIG_FILE:-$HOME/.aws/config}"
	[[ -r "$config" ]] || return 0
	awk '
	function emit() { if (name != "" && eligible) print name }
	/^[[:space:]]*\[[^]]+\][[:space:]]*([#;].*)?$/ {
	emit(); name=""; eligible=0
	section=$0
	sub(/^[[:space:]]*\[/, "", section)
	sub(/\].*$/, "", section)
	if (section == "default") name="default"
	else if (section ~ /^profile[[:space:]]+/) {
		sub(/^profile[[:space:]]+/, "", section); name=section
}
next
}
/^[[:space:]]*(#|;|$)/ { next }
	{
		line=$0
		sub(/^[[:space:]]*/, "", line)
		split(line, pair, "=")
		key=pair[1]
		sub(/[[:space:]]*$/, "", key)
		if (name != "" && (key == "role_arn" || key == "source_profile" || key == "mfa_serial" || key == "role_session_name")) eligible=1
}
END { emit() }
' "$config"
}

_aws_me_clean_env() {
	env -u AWS_PROFILE -u AWS_DEFAULT_PROFILE \
		-u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY \
		-u AWS_SESSION_TOKEN -u AWS_SECURITY_TOKEN \
		-u AWS_DEFAULT_REGION -u AWS_REGION "$@"
}

# Reads AWS CLI's native AssumeRole cache; never prompts or renews credentials.
# Cache entries are not keyed by readable profile name. If matching is ambiguous,
# report unavailable rather than claim a potentially wrong expiration.
_aws_me_remaining() {
	local profile="$1" role session role_name account file matches=0 expiration="" epoch now left
	role=$(_aws_me_clean_env aws configure get role_arn --profile "$profile" 2>/dev/null) || true
	session=$(_aws_me_clean_env aws configure get role_session_name --profile "$profile" 2>/dev/null) || true
	if [[ ! "$role" =~ ^arn:[^:]+:iam::([0-9]{12}):role/(.+)$ ]]; then
		echo 'Session time: unavailable (not a direct AssumeRole profile).'
		return 0
	fi
	account="${BASH_REMATCH[1]}"
	role_name="${BASH_REMATCH[2]##*/}"
	# If role_session_name is not explicitly configured, the CLI generates one.
	# Matching by role alone can be ambiguous, so never guess.
	if [[ -z "$session" ]]; then
		echo 'Session time: unavailable (set role_session_name in AWS config).'
		return 0
	fi
	for file in "$HOME"/.aws/cli/cache/*.json; do
		[[ -f "$file" ]] || continue
		if jq -e --arg acct "$account" --arg role "$role_name" --arg sess "$session" '
			(.AssumedRoleUser.Arn // "") ==
			("arn:aws:sts::" + $acct + ":assumed-role/" + $role + "/" + $sess)
			and (.Credentials.Expiration | type == "string")
			' "$file" >/dev/null 2>&1; then
			((matches+=1))
			expiration=$(jq -r '.Credentials.Expiration' "$file")
		fi
	done
	if (( matches != 1 )); then
		echo "Session time: unavailable ($matches matching cache entries)."
		return 0
	fi
	epoch=$(date -d "$expiration" +%s 2>/dev/null) || {
		echo 'Session time: unavailable (invalid expiration).'; return 0;
	}
now=$(date +%s)
left=$((epoch-now))
if (( left <= 0 )); then
	echo 'AWS session expired.'
else
	printf 'AWS session remaining: %dh %02dm %02ds\n' \
		"$((left/3600))" "$(((left%3600)/60))" "$((left%60))"
fi
}

# Run AWS CLI through Expect only when a fresh MFA challenge is needed.
# Expect reads the code from the real terminal with echo enabled.
_aws_me_auth_visible() {
	local profile="$1"
	if ! command -v expect >/dev/null 2>&1; then
		echo 'Missing dependency: expect (install it to enable visible MFA input).' >&2
		return 127
	fi

	_aws_me_clean_env env AWS_ME_TARGET_PROFILE="$profile" expect -c '
	log_user 0
	set timeout -1
	set profile $env(AWS_ME_TARGET_PROFILE)
	spawn -noecho aws --profile $profile sts get-caller-identity --output json
	set seen ""
	expect {
		-re {Enter MFA code for[^\r\n]*: ?} {
			send_user "Enter MFA code (visible): "
			# The terminal, not AWS CLI, handles the user input.
			# Use cooked mode with echo for the six digits.
			catch {exec stty echo < /dev/tty}
			expect_user -re {([^\r\n]*)\r?\n} {
				set code $expect_out(1,string)
				if {![regexp {^[0-9]{6}$} $code]} {
					send_user "Invalid MFA code format.\n"
					exit 2
}
send -- "$code\r"
}
exp_continue
}
-re {.+\n} {
	append seen $expect_out(0,string)
	exp_continue
}
eof {
	set result [wait]
	if {[lindex $result 3] != 0} {
		send_user $seen
		exit [lindex $result 3]
}
exit 0
}
}
'
}
_aws_me_logout() {
	local profile="$1"
	local role session account role_name file removed=0

	if ! _aws_me_profiles | grep -Fxq -- "$profile"; then
		echo "Not a configured role/MFA profile: $profile" >&2
		return 1
	fi

	role=$(_aws_me_clean_env aws configure get role_arn --profile "$profile" 2>/dev/null) || true
	session=$(_aws_me_clean_env aws configure get role_session_name --profile "$profile" 2>/dev/null) || true

	if [[ ! "$role" =~ ^arn:[^:]+:iam::([0-9]{12}):role/(.+)$ ]]; then
		echo "Cannot identify AssumeRole cache for: $profile" >&2
		return 1
	fi

	if [[ -z "$session" ]]; then
		echo "Missing role_session_name for: $profile" >&2
		return 1
	fi

	account="${BASH_REMATCH[1]}"
	role_name="${BASH_REMATCH[2]##*/}"

	for file in "$HOME"/.aws/cli/cache/*.json; do
		[[ -f "$file" && ! -L "$file" ]] || continue

		if jq -e \
			--arg acct "$account" \
			--arg role "$role_name" \
			--arg sess "$session" '
		(.AssumedRoleUser.Arn // "") ==
		("arn:aws:sts::" + $acct +
		":assumed-role/" + $role + "/" + $sess)
		' "$file" >/dev/null 2>&1; then

		rm -- "$file" || return 1
		((removed+=1))
		fi
	done

	if [[ "${AWS_PROFILE:-}" == "$profile" ]]; then
		unset AWS_PROFILE AWS_DEFAULT_PROFILE \
			AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
			AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
			AWS_SESSION_EXPIRATION AWS_DEFAULT_REGION AWS_REGION
	fi

	printf 'AWS profile logged out: %s\n' "$profile"
	printf 'Removed cache entries: %d\n' "$removed"
}

_aws_me_sessions() {
	local profile role session account role_name file
	local expiration epoch now left found=0
	local cache_dir="$HOME/.aws/cli/cache"

	now=$(date +%s)

	printf '%-36s %-14s %s\n' "PROFILE" "ACCOUNT" "REMAINING"
	printf '%-36s %-14s %s\n' "-------" "-------" "---------"

	while IFS= read -r profile; do
		role=$(_aws_me_clean_env aws configure get role_arn \
			--profile "$profile" 2>/dev/null) || continue

		session=$(_aws_me_clean_env aws configure get role_session_name \
			--profile "$profile" 2>/dev/null) || continue

		[[ -n "$session" ]] || continue

		if [[ ! "$role" =~ ^arn:[^:]+:iam::([0-9]{12}):role/(.+)$ ]]; then
			continue
		fi

		account="${BASH_REMATCH[1]}"
		role_name="${BASH_REMATCH[2]##*/}"

		local latest_epoch=0

		for file in "$cache_dir"/*.json; do
			[[ -f "$file" ]] || continue

			expiration=$(jq -er \
				--arg acct "$account" \
				--arg role "$role_name" \
				--arg sess "$session" '
			select(
				(.AssumedRoleUser.Arn // "") ==
				("arn:aws:sts::" + $acct +
				":assumed-role/" + $role + "/" + $sess)
			)
			| .Credentials.Expiration
			' "$file" 2>/dev/null) || continue

			epoch=$(date -d "$expiration" +%s 2>/dev/null) || continue

			if (( epoch > latest_epoch )); then
				latest_epoch=$epoch
			fi
		done

		left=$((latest_epoch - now))

		if (( left > 0 )); then
			printf '%-36s %-14s %02dh %02dm %02ds\n' \
				"$profile" "$account" \
				"$((left / 3600))" \
				"$(((left % 3600) / 60))" \
				"$((left % 60))"

			((found+=1))
		fi

	done < <(_aws_me_profiles)

	if (( found == 0 )); then
		echo "No active AWS sessions."
	fi

	printf '\nActive sessions: %d\n' "$found"
}

aws-me() {
	local profile identity account arn

	if [[ "${1:-}" == "--sessions" ]]; then
		if (( $# != 1 )); then
			echo 'Usage: aws-me --sessions' >&2
			return 2
		fi

		_aws_me_sessions
		return $?
	fi

	if [[ "${1:-}" == "--logout" ]]; then

		if (( $# != 2 )); then
			echo 'Usage: aws-me --logout PROFILE' >&2
			return 2
		fi

		_aws_me_logout "$2"
		return $?
	fi

	if [[ "${1:-}" == "--logout-all" ]]; then
		if (( $# != 1 )); then
			echo 'Usage: aws-me --logout-all' >&2
			return 2
		fi

		local file removed=0

		for file in "$HOME"/.aws/cli/cache/*.json; do
			[[ -f "$file" && ! -L "$file" ]] || continue
			rm -- "$file" || return 1
			((removed+=1))
		done

		unset AWS_PROFILE AWS_DEFAULT_PROFILE \
			AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY \
			AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
			AWS_SESSION_EXPIRATION AWS_DEFAULT_REGION AWS_REGION

		printf 'All AWS CLI AssumeRole sessions cleared.\n'
		printf 'Removed cache entries: %d\n' "$removed"
		return 0
	fi

	if (( $# == 0 )); then
		if [[ -z "${AWS_PROFILE:-}" ]]; then
			echo 'No AWS profile selected in this terminal.'
			echo 'Use aws-me <TAB> to select a profile.'
		else
			printf 'AWS profile: %s\n' "$AWS_PROFILE"
			_aws_me_remaining "$AWS_PROFILE"
		fi
		return 0
	fi
	if (( $# != 1 )); then
		echo 'Usage: aws-me [profile|--unset]' >&2; return 2
	fi
	case "$1" in
		--unset)
			unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ACCESS_KEY_ID \
				AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN \
				AWS_SESSION_EXPIRATION AWS_DEFAULT_REGION AWS_REGION
			echo 'AWS profile selection cleared in this terminal.'
			echo 'Note: AWS default credential chain may still provide access.'
			return 0 ;;
		-*) echo "Unknown option: $1" >&2; return 2 ;;
	esac
	profile="$1"
	if ! _aws_me_profiles | grep -Fxq -- "$profile"; then
		echo "Not a configured role/MFA profile: $profile" >&2
		return 1
	fi
	echo "Checking AWS profile: $profile"
	# First resolve the role via Expect; it handles an MFA prompt visibly.
	# Then query the cached identity normally for structured JSON.
	if ! _aws_me_auth_visible "$profile"; then
		echo 'AWS authentication failed; current shell profile unchanged.' >&2
		return 1
	fi
	identity=$(_aws_me_clean_env aws --profile "$profile" sts get-caller-identity --output json) || {
		echo 'AWS authentication failed; current shell profile unchanged.' >&2
			return 1
	}
account=$(jq -er '.Account' <<< "$identity") || return 1
arn=$(jq -er '.Arn' <<< "$identity") || return 1
local credentials

# Export temporary credentials for AWS SDK-based tools (CDK, etc.).
credentials=$(
	_aws_me_clean_env aws configure export-credentials \
		--profile "$profile" --format env
	) || {
		echo 'Failed to export AWS credentials; current shell profile unchanged.' >&2
			return 1
	}

	# Clear credentials from the previously selected profile.
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN \
		AWS_SECURITY_TOKEN AWS_SESSION_EXPIRATION AWS_DEFAULT_PROFILE \
		AWS_DEFAULT_REGION AWS_REGION

	export AWS_PROFILE="$profile"

	# Apply credentials to the current shell.
	eval "$credentials"

	printf 'AWS profile: %s\nAccount: %s\nIdentity: %s\n' \
		"$profile" "$account" "$arn"

	_aws_me_remaining "$profile"
}

_aws_me_active_profiles() {
	local profile role session account role_name file
	local expiration epoch now latest_epoch
	local cache_dir="$HOME/.aws/cli/cache"
	local has_active_cache=0

	now=$(date +%s)

	# Fast check: is there at least one non-expired cache entry?
	for file in "$cache_dir"/*.json; do
		[[ -f "$file" && ! -L "$file" ]] || continue

		expiration=$(jq -er '.Credentials.Expiration // empty' "$file" 2>/dev/null) || continue
		epoch=$(date -d "$expiration" +%s 2>/dev/null) || continue

		if (( epoch > now )); then
			has_active_cache=1
			break
		fi
	done

	# No active cache: return immediately, without starting AWS CLI.
	(( has_active_cache )) || return 0

	while IFS= read -r profile; do
		role=$(_aws_me_clean_env aws configure get role_arn --profile "$profile" 2>/dev/null) || continue
		session=$(_aws_me_clean_env aws configure get role_session_name --profile "$profile" 2>/dev/null) || continue

		[[ -n "$session" ]] || continue

		if [[ ! "$role" =~ ^arn:[^:]+:iam::([0-9]{12}):role/(.+)$ ]]; then
			continue
		fi

		account="${BASH_REMATCH[1]}"
		role_name="${BASH_REMATCH[2]##*/}"
		latest_epoch=0

		for file in "$cache_dir"/*.json; do
			[[ -f "$file" && ! -L "$file" ]] || continue

			expiration=$(jq -er \
				--arg acct "$account" \
				--arg role "$role_name" \
				--arg sess "$session" '
			select(
				(.AssumedRoleUser.Arn // "") ==
				("arn:aws:sts::" + $acct +
				":assumed-role/" + $role + "/" + $sess)
			)
			| .Credentials.Expiration
			' "$file" 2>/dev/null) || continue

			epoch=$(date -d "$expiration" +%s 2>/dev/null) || continue

			if (( epoch > latest_epoch )); then
				latest_epoch=$epoch
			fi
		done

		if (( latest_epoch > now )); then
			printf '%s\n' "$profile"
		fi
	done < <(_aws_me_profiles)
}

_aws_me_completion() {
	local current profiles
	COMPREPLY=()

	current="${COMP_WORDS[COMP_CWORD]}"

	case "$COMP_CWORD" in
		1)
			profiles=$(_aws_me_profiles)

			mapfile -t COMPREPLY < <(
				compgen -W "--unset --logout --logout-all --sessions $profiles" -- "$current"
			)
			;;
		2)
			if [[ "${COMP_WORDS[1]}" == "--logout" ]]; then
				profiles=$(_aws_me_active_profiles)

				# No active sessions: no suggestions.
				[[ -n "$profiles" ]] || return 0

				mapfile -t COMPREPLY < <(
					compgen -W "$profiles" -- "$current"
				)
			fi
			;;
	esac

	return 0
}

complete -F _aws_me_completion aws-me

# Do not overwrite existing AWS completion if it is already configured.
if command -v aws_completer >/dev/null 2>&1 && ! complete -p aws >/dev/null 2>&1; then
	complete -C "$(command -v aws_completer)" aws
fi
