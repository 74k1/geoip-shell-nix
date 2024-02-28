#!/bin/sh
# shellcheck disable=SC2154,SC1090

# geoip-shell-backup-nft.sh

# nftables-specific library for the -backup script

. "$_lib-nft.sh" || die -u


#### FUNCTIONS

# resets firewall rules, destroys geoip ipsets and then initiates restore from file
restorebackup() {
	printf '%s\n' "Preparing to restore $p_name from backup..."

	getconfig Lists lists "$conf_file_bak"
	getconfig BackupExt bk_ext "$conf_file_bak"

	set_extract_cmd "$bk_ext"

	printf %s "Restoring files from backup... "
	for list_id in $lists; do
		bk_file="$bk_dir/$list_id.$bk_ext"
		iplist_file="$iplist_dir/${list_id}.iplist"

		[ ! -s "$bk_file" ] && rstr_failed "$ERR '$bk_file' is empty or doesn't exist."

		# extract elements and write to $iplist_file
		$extract_cmd "$bk_file" > "$iplist_file" || rstr_failed "$FAIL extract backup file '$bk_file'."
		[ ! -s "$iplist_file" ] && rstr_failed "$FAIL extract ip list for $list_id."
		# count lines in the iplist file
		line_cnt=$(wc -l < "$iplist_file")
		debugprint "\nLines count in $list_id backup: $line_cnt"
	done

	cp "$status_file_bak" "$status_file" || rstr_failed "$FAIL restore the status file."
	cp "$conf_file_bak" "$conf_file" || rstr_failed "$FAIL restore the config file."

	OK

	# remove geoip rules
	rm_all_georules || rstr_failed "Error removing firewall rules."

	export force_read_geotable=1
	call_script "$script_dir/${p_name}-apply.sh" add -l "$lists"; apply_rv=$?
	rm "$iplist_dir/"*.iplist 2>/dev/null
	[ "$apply_rv" != 0 ] && rstr_failed "$FAIL restore the firewall state from backup." "reset"
	:
}

rstr_failed() {
	rm "$iplist_dir/"*.iplist 2>/dev/null
	echolog -err "$1"
	[ "$2" = reset ] && {
		echolog -err "*** Geoip blocking is not working. Removing geoip firewall rules and cron jobs. ***"
		call_script "$script_dir/${p_name}-uninstall.sh" -c
	}
	die -u
}

bk_failed() {
	rm -f "$temp_file" "$bk_dir/"*.new 2>/dev/null
	die -u "$FAIL back up $p_name ip sets."
}

# Saves current firewall state to a backup file
create_backup() {
	set_archive_type

	getconfig Lists lists "$conf_file"
	temp_file="/tmp/${p_name}_backup.tmp"
	mkdir "$bk_dir" 2>/dev/null

	# back up current ip sets
	printf %s "Creating backup of $p_name ip sets... "
	for list_id in $lists; do
		bk_file="${bk_dir}/${list_id}.${archive_ext:-bak}"
		iplist_file="$iplist_dir/${list_id}.iplist"
		getstatus "$status_file" "PrevDate_${list_id}" list_date || bk_failed
		ipset="${list_id}_${list_date}_${geotag}"

		rm "$temp_file" 2>/dev/null
		# extract elements and write to $temp_file
		nft list set inet "$geotable" "$ipset" |
			sed -n -e /"elements[[:space:]]*=[[:space:]]*{"/\{ -e p\;:1 -e n\; -e p\; -e /\}/q\;b1 -e \} > "$temp_file"
		[ ! -s "$temp_file" ] && bk_failed

		[ "$debugmode" ] && backup_len="$(wc -l < "$temp_file")"
		debugprint "\n$list_id backup length: $backup_len"

		$compr_cmd < "$temp_file" > "${bk_file}.new"; rv=$?
		[ "$rv" != 0 ] || [ ! -s "${bk_file}.new" ] && bk_failed
	done
	OK

	rm "$temp_file" 2>/dev/null

	for f in "${bk_dir}"/*.new; do
		mv -- "$f" "${f%.new}" || bk_failed
	done

	cp "$status_file" "$status_file_bak" || bk_failed
	setconfig "BackupExt=${archive_ext:-bak}"
	cp "$conf_file" "$conf_file_bak"  || bk_failed
}