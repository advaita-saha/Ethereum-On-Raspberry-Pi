#!/bin/bash

# Read custom config flags from /boot/firmware/config.txt
config_read_file() {
    (grep -E "^${2}=" -m 1 "${1}" 2>/dev/null || echo "VAR=UNDEFINED") | head -n 1 | cut -d '=' -f 2-;
}

config_get() {
    val="$(config_read_file /boot/firmware/config.txt "${1}")";
    printf -- "%s" "${val}";
}

# Function: echolog
# Description: Logs messages with a timestamp prefix. If no arguments are provided,
#              reads from stdin and logs each line. Outputs to console and appends to $LOGI file.
LOGI="/var/log/web3pi.log"
echolog(){
    if [ $# -eq 0 ]
    then cat - | while read -r message
        do
                echo "$(date +"[%F %T %Z] -") $message" | tee -a $LOGI
            done
    else
        echo -n "$(date +'[%F %T %Z]') - " | tee -a $LOGI
        echo "$*" | tee -a $LOGI
    fi
}

# Function: get_install_stage
# Description: A function that retrieves the installation stage from the file /root/.install_stage.
get_install_stage() {
    local file_path=$1
    if [ -f "/root/.install_stage" ]; then
        local number=$(cat "/root/.install_stage")
        echo "$number"
    else
        echolog "File /root/.install_stage does not exist."
        return 0
    fi
}

# Function: set_status
# Function to write a string to a file with status
set_status() {
  local status="$1"  # Assign the first argument to a local variable
  echo "STAGE $(get_install_stage): $status" > /opt/web3pi/status.txt  # Write the string to the file
  echolog " "
  echolog "STAGE $(get_install_stage): $status"
  echolog " "
}

# Function to calculate average ping time
calculate_average_ping() {
  local server=$1
  local server_address=$(echo "$server" | sed -E 's#^https?://##')
  local avg_ping=$(ping -c 3 -q "$server_address" 2>/dev/null | grep -oP '(?<=rtt min/avg/max/mdev = )[0-9.]+(?=/)')
  echo "$avg_ping"
}

echolog "Nimbus unified client run script (nimbus_unified.sh)"

nimbus_unified_el_port="$(config_get nimbus_unified_el_port)";
nimbus_unified_cl_port="$(config_get nimbus_unified_cl_port)";
eth_network="$(config_get eth_network)";

# Default ports when not present in config.txt
if [ "${nimbus_unified_el_port}" = "UNDEFINED" ]; then
  nimbus_unified_el_port=30303
fi
if [ "${nimbus_unified_cl_port}" = "UNDEFINED" ]; then
  nimbus_unified_cl_port=9000
fi

# Checking internet connection
echolog "Checking internet connection"

pingServerAdr="github.com"
ping_n=0
ping_max=10

ping -c 1 $pingServerAdr > /dev/null 2>&1
while [ $? -ne 0 ]; do
  echolog -e "\e[1A\e[K $(date): test connection [$ping_n/$ping_max] - ${pingServerAdr}"
  sleep 6
  let "ping_n+=1"
  [[ ${ping_n} -gt ${ping_max} ]] && echolog "Internet access is necessary" && exit 1
  ping -c 1 $pingServerAdr > /dev/null 2>&1
done


# Directory for the Nimbus unified client (holds both execution and consensus data)
nu_dir="/mnt/storage/.nimbus-unified/data/shared_${eth_network}_0"

echolog "$(date): Connected - ${pingServerAdr}"
echolog "nimbus_unified_el_port = ${nimbus_unified_el_port}"
echolog "nimbus_unified_cl_port = ${nimbus_unified_cl_port}"
echolog "eth_network = ${eth_network}"
echolog "nu_dir = ${nu_dir}"

success=false

# The unified data directory holds execution layer state as well, so checkpoint
# sync (and the datadir cleanup on failure) must only happen on a fresh install.
if [ -d "${nu_dir}/db" ]; then
  echolog "Existing database found in ${nu_dir} - skipping checkpoint sync"
  success=true
else
  # Pre-seeded execution layer database published by the Nimbus team. Restoring
  # it is far quicker than letting the execution layer sync from scratch on a
  # Pi. Snapshots exist for mainnet and hoodi only - other networks just fall
  # through and sync normally.
  #
  # The archives are not laid out consistently - mainnet packs "ecdb/" at the
  # top level while hoodi wraps it in "hoodi-latest/ecdb/" - so extraction goes
  # to a staging directory and the ecdb is located and moved into place after.
  # Staging lives inside the data dir so the move is a same-filesystem rename.
  el_db_url="https://eth1-db.nimbus.team/${eth_network}-latest.tar.gz"
  el_db_tmp="${nu_dir}/.snapshot-download"

  # Logs the unpacked size once a minute. curl's own progress meter is
  # carriage-return based and journald renders it as unreadable "blob data",
  # so it is switched off and the growing staging directory is measured instead.
  # The archive is mostly already-compressed sst files, so its download size is
  # a close enough stand-in for the unpacked total to give a percentage.
  el_db_progress() {
    local prev=0 prev_t cur now
    prev_t="$(date +%s)"
    while sleep 60; do
      cur="$(du -sb "${el_db_tmp}" 2>/dev/null | cut -f1)"
      now="$(date +%s)"
      [ -z "$cur" ] && cur=0
      echolog "$(awk -v cur="$cur" -v prev="$prev" -v dt="$((now - prev_t))" -v total="$el_db_size" 'BEGIN {
        gib = 1024 * 1024 * 1024
        rate = (dt > 0) ? (cur - prev) / dt : 0
        line = sprintf("Snapshot progress: %.1f GiB", cur / gib)
        if (total > 0)
          line = line sprintf(" of ~%.1f GiB (%d%%)", total / gib, (cur * 100) / total)
        line = line sprintf(" - %.1f MiB/s", rate / (1024 * 1024))
        if (rate > 0 && total > cur)
          line = line sprintf(" - ETA %dh%02dm", (total - cur) / rate / 3600, ((total - cur) / rate % 3600) / 60)
        print line
      }')"
      prev="$cur"
      prev_t="$now"
    done
  }

  if [ -d "${nu_dir}/ecdb" ]; then
    echolog "Execution database already present in ${nu_dir}/ecdb - skipping snapshot download"
  else
    echolog "Downloading execution database snapshot: ${el_db_url}"

    el_db_size="$(curl -fsIL --max-time 60 "$el_db_url" | grep -i '^content-length:' | tail -n 1 | tr -dc '0-9')"
    [ -z "$el_db_size" ] && el_db_size=0
    if [ "$el_db_size" -gt 0 ]; then
      echolog "$(awk -v s="$el_db_size" 'BEGIN { printf "Snapshot size: %.1f GiB - this can take several hours", s / (1024 * 1024 * 1024) }')"
    else
      echolog "Snapshot size unknown - this can take several hours"
    fi
    df -h /mnt/storage | echolog

    mkdir -p "$nu_dir"

    # The progress helper runs in the background so the transfer itself stays in
    # the foreground and PIPESTATUS still reports curl and tar.
    el_db_progress &
    el_db_progress_pid=$!

    # The server does not honour range requests, so a broken transfer cannot be
    # resumed anyway - stream straight into tar rather than staging the archive
    # on disk, which would otherwise need close to twice the space.
    #
    # --speed-limit/--speed-time abort a connection that has silently gone dead
    # (curl will otherwise wait on it forever). Retrying is done out here rather
    # than with curl's own --retry: without resume that restarts the body from
    # byte 0, which would splice a second archive into the middle of tar's input
    # stream, so every attempt needs to extract into an empty staging directory.
    #
    # --no-same-owner: the archive is packed on a Mac and carries its uids,
    # which root would otherwise restore onto the database files.
    el_db_attempt=1
    el_db_max_attempts=3
    while true; do
      rm -rf "$el_db_tmp"
      mkdir -p "$el_db_tmp"

      curl -fL --speed-limit 102400 --speed-time 120 --no-progress-meter "$el_db_url" \
        | tar -xzf - --no-same-owner -C "$el_db_tmp"
      el_db_status=("${PIPESTATUS[@]}")

      if [ "${el_db_status[0]}" -eq 0 ] && [ "${el_db_status[1]}" -eq 0 ]; then
        el_db_src="$(find "$el_db_tmp" -mindepth 1 -maxdepth 2 -type d -name ecdb | head -n 1)"
        if [ -n "$el_db_src" ]; then
          mv "$el_db_src" "${nu_dir}/ecdb"
          break
        fi
        echolog "No ecdb directory found in the extracted snapshot - unexpected archive layout"
        el_db_status=(0 1)
      fi

      if [ "$el_db_attempt" -ge "$el_db_max_attempts" ]; then
        break
      fi

      echolog "Snapshot attempt ${el_db_attempt}/${el_db_max_attempts} failed (curl=${el_db_status[0]} tar=${el_db_status[1]}) - restarting the download"
      el_db_attempt=$((el_db_attempt + 1))
      sleep 30
    done

    rm -rf "$el_db_tmp"

    kill "$el_db_progress_pid" 2>/dev/null
    wait "$el_db_progress_pid" 2>/dev/null

    if [ "${el_db_status[0]}" -eq 0 ] && [ "${el_db_status[1]}" -eq 0 ]; then
      echolog "Execution database snapshot unpacked into ${nu_dir}/ecdb"
    else
      echolog "Snapshot download failed (curl=${el_db_status[0]} tar=${el_db_status[1]}) - the execution layer will sync from scratch"
      rm -rf "${nu_dir}/ecdb"
    fi
  fi

  # File with the list of servers
  SERVERS_FILE="/opt/web3pi/Ethereum-On-Raspberry-Pi/distros/raspberry_pi/scripts/servers_list_${eth_network}.txt"

  if [ -f "${SERVERS_FILE}" ]; then
      echolog "SERVERS_FILE = ${SERVERS_FILE}"
  else
      echolog "File ${SERVERS_FILE} does not exist."
      exit 1
  fi

  bash /opt/web3pi/Ethereum-On-Raspberry-Pi/distros/raspberry_pi/scripts/servers_sort.sh $SERVERS_FILE

  sleep 1

  # Iterate through each server from the list
  while read -r server; do
    if [[ -n "$server" ]]; then
      echolog "Attempting to sync with server: $server"
      avg_ping=$(calculate_average_ping "$server")
      echolog "Average ping = $avg_ping ms"

      # Run the checkpoint sync command and capture output
      output=$(nimbus trustedNodeSync --network=${eth_network} --data-dir="$nu_dir" --trusted-node-url="$server" --backfill=false 2>&1)

      # Check if output contains line indicating success
      echo "$output" | grep -q "Done, your beacon node is ready to serve you!"
      finished=$?

      # Check the output for success messages
      if [ "$finished" -eq 0 ]; then
        echolog "Sync successful with server: $server "
        success=true
        break
      else
        echolog "Sync failed with server: $server, trying next server..."
        # Only the beacon database is discarded - the execution database
        # (ecdb) was just downloaded and must survive.
        echolog "Removing $nu_dir/db "
        rm -rf "$nu_dir/db"
      fi
    fi
  done < "$SERVERS_FILE"

  # If trustedNodeSync failed with all, try downloading finalized state via curl from each server
  if [ "$success" = false ]; then
    echolog "All trustedNodeSync attempts failed. Trying to download finalized state from servers..."

    while read -r server; do
      if [[ -n "$server" ]]; then
        url="${server%/}/eth/v2/debug/beacon/states/finalized"
        echolog "Attempting to download finalized state from: $url"

        mkdir -p "$nu_dir"
        curl -sSf -o "$nu_dir/state.finalized.ssz" -H 'Accept: application/octet-stream' "$url"
        if [ $? -eq 0 ]; then
          echolog "Successfully downloaded finalized state from $server"
          success=true
          state_finalized=true
          break
        else
          echolog "Failed to download from $server, trying next..."
          rm -f "$nu_dir/state.finalized.ssz"
        fi
      fi
    done < "$SERVERS_FILE"
  fi
fi

# If the checkpoint sync was successful (or a database already exists)
if [ "$success" = true ]; then
  echolog "Run Nimbus unified client"
  # Execution and consensus run in one process; the Engine API stays internal
  # (localhost, auto-generated JWT), so no exec_url/jwt-secret wiring is needed.
  # Note: --rpc-api only accepts eth/debug/admin, but net_* and web3_* methods
  # are always served. WS is required by the node monitor (w3p_bnm) and shares
  # the HTTP server port (8545) - unlike geth there is no separate WS port.
  #
  # The --debug-* options are hidden execution-layer tuning flags (verified
  # against v0.4.0; names may change in future releases): dynamic persist batch
  # size, parallel state root computation and optimistic state prefetch
  # (pre-executes block transactions on background threads to warm the DB
  # caches).
  #
  # The DB caches (rocksdb block cache, rdb key/branch/vtx caches) are left at
  # their defaults - overriding them was never shown to help on the Pi.
  nimbus --non-interactive --network=${eth_network} --data-dir=${nu_dir} --execution-tcp-port=${nimbus_unified_el_port} --execution-udp-port=${nimbus_unified_el_port} --beacon-tcp-port=${nimbus_unified_cl_port} --beacon-udp-port=${nimbus_unified_cl_port} --rpc=true --rpc-api=eth --ws=true --ws-api=eth --http-port=8545 --http-address=0.0.0.0 --rest=true --rest-port=5052 --rest-address=0.0.0.0 --rest-allow-origin='*' --enr-auto-update --debug-dynamic-batch-size=true --debug-parallel-state-root=true --debug-optimistic-state-prefetch=true ${state_finalized:+--finalized-checkpoint-state="$nu_dir/state.finalized.ssz"}
else
  # If no server was successful
  echolog "All sync attempts failed. Nimbus unified client will not be started."
  exit 1
fi
