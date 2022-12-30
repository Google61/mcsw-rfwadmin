#!/bin/bash
###############################################################################
# Bash script for managing a Minecraft server. Include support for starting,
# stopping, saving and backups. It follows the standard init.d script usage.
#
# Author
# Thue Janus Kristensen, thuejk@gmail.com
# 
# Based on work by James Logsdon, ents.girsbrain.org
# Based on work by Pierre Christoffersen, www.nahaz.se
###############################################################################

MAP_DIR="$PATH_BASE/maps"

RESTART_TIME=6
MAX_ATTEMPTS=3

if [ "$MEM_LOW" == "" ]; then
    MEM_LOW="1024M"
fi
if [ "$MEM_HIGH" == "" ]; then
    MEM_HIGH="1024M"
fi
if [ "$WORLD" == "" ]; then
    WORLD="world"
fi
if [ "$SERVER_ARGS" == "" ]; then
    SERVER_ARGS="-server"
fi
if [ "$USE_SAVEOFF" == "" ]; then
    USE_SAVEOFF=false
fi

PATH_SERVER="$PATH_BASE/servers/$SERVER_SUBDIR"
PATH_RUN="$PATH_BASE/servers/$SERVER_SUBDIR/server"
PATH_BACKUP="$PATH_BASE/servers/$SERVER_SUBDIR/backups"

#TMUX session name. Used to be server-specific, but now we just
#specify a per-server tmux socket file instead. This also fixes
#problem with systemd per-service temp files, with tmux storing
#sockets per default in /tmp...
TMUX="rfwadmin"
TMUX_SOCKET="${PATH_SERVER}/tmux.socket"
TMUX_LOG="${PATH_SERVER}/tmux.log"

#Log location changed with 1.7. SERVER_LOG="" means try to guess location
SERVER_LOG=""

#seconds
LOCK_FILE_TIMEOUT=30
LOCKFILE="${PATH_SERVER}/minecraft.sh.lock"
LOCKFILE2="${LOCKFILE}.lock"

PATH_MINECRAFT_PID="${PATH_SERVER}/minecraft.pid"

SERVER="java -Xms${MEM_LOW} -Xmx${MEM_HIGH} ${SERVER_ARGS} -jar ${FILE_JAR} nogui"

#exit on first error
set -e
#noclobber for race-free locking
set -o noclobber

function set_server_log() {
    POST17="${PATH_RUN}/logs/latest.log"
    PRE17="${PATH_RUN}/server.log"
    if is_server_online; then
	#Determine logging method: look at which files the server has open
        PID=`cat $PATH_MINECRAFT_PID`
	if [ "`lsof -n -w -p$PID |grep -P 'server/server.log$'`" != "" ]; then
	    SERVER_LOG=$PRE17;
	else
	    SERVER_LOG=$POST17;
	fi
    elif [ ! -f $PRE17 ]; then
	SERVER_LOG="$POST17"
    elif [ ! -f $POST17 ]; then
	SERVER_LOG="$PRE17"
    else
	#get the file which was modified last
	SERVER_LOG="`echo -e "${POST17}\n${PRE17}" | sort -n -t _ -k 2 | tail -1`"
    fi
}

function send_command() {
    if ! is_server_online; then
	echo "server is offline"
	exit 1;
    fi
    tmux_cmd "$1"
}

function list() {
    if ! is_server_online; then
        echo "Server is offline"
        return 1
    fi

    local OFFSET=`cat "$SERVER_LOG" |wc -l`
    local OFFSET=`expr $OFFSET + 1`
    #local PREG='^\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\] Connected players: .*(.\[m)?'
    local PREG='^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) (Connected players: |There are \d+/\d+ players online:)'
    if ! tmux_cmd "list" 1 "$PREG" "$SERVER_LOG"; then
	echo "Failed to find list output!";
	return 1;
    fi

    LIST_LINE=`tail -n +$OFFSET "$SERVER_LOG" | grep -P "$PREG" | head -n 1`

    local PREG_13='^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) There are \d+/\d+ players online:$'

    if [ "`echo "$LIST_LINE"|grep -P "$PREG_13"`" != "" ]; then
        #Horrible 1.3+ format 2-line format
	local FIRST_LINE_FOUND="searching"
	local LINES=`tail -n +$OFFSET "$SERVER_LOG"`
	 while read -r line; do
	    if [ "$FIRST_LINE_FOUND" == "done" ]; then
	        true #nothing
	    elif [ "$FIRST_LINE_FOUND" == "next" ]; then
		LIST_LINE=`echo "$line" | sed 's/.*]:\? \?\(.*\)/\1/'`
		LIST_LINE=`echo "$LIST_LINE" | sed 's/,//g'`
		LIST_LINE=`echo "$LIST_LINE" | sed 's/\x1B\[m//g'` #craftbukkit add this one
		FIRST_LINE_FOUND="done"
	    elif [ "`echo $line|grep -P \"$PREG_13\"`" != "" ]; then
		FIRST_LINE_FOUND="next"
	    fi
	done <<< "$LINES"

	if [ "$FIRST_LINE_FOUND" != "done" ]; then
	    echo "Failed to find list output. This should not be possible";
	    return 1;
	fi
    else
	LIST_LINE=`echo "$LIST_LINE" | sed 's/.*: \([^\[]*\)\(.\[m\)\?/\1/' | sed 's/,//g'`
    fi

    return 0
}

function is_server_online() {
    if [ -f $PATH_MINECRAFT_PID ]; then
        PID=`cat $PATH_MINECRAFT_PID`
        if [ -z $PID ]; then
            local ONLINE=0
        else
            local ONLINE=$(ps --pid $PID | grep java | wc -l)
        fi

        if [ $ONLINE -eq 0 ]; then
            server_pid_remove
        fi
    else
        local ONLINE=0
    fi

    if [ $ONLINE -eq 0 ]; then
        return 1
    else
        return 0
    fi
}

function tmux_running() {
    #In theory I should be able to run "tmux start"
    local LINE=$(tmux -S $TMUX_SOCKET ls 2>&1 |grep -P "^${TMUX}:")
    if [ "$LINE" = "" ]; then
	return 1
    else
        return 0
    fi
}

function get_tmux_pid() {
    if ! tmux_running; then
	echo "tmux doesn't seem to be running, so can't find tmux pid";
	return 1
    fi
    TMUX_PID=$(tmux -S $TMUX_SOCKET list-panes -F '#{pane_pid}' -t $TMUX)

    return 0;
}

function tmux_start() {
    if tmux_running; then
        return 0
    fi

    #If running as normal user, the user might have a tmux config
    #for normal interactive work. We don't want to use that, so create
    #a temporary empty file to use as tmux config instead.
    TMUX_CONF=`mktemp`
    echo -n "Starting tmux session... "
    tmux -S $TMUX_SOCKET -f "$TMUX_CONF" new-session -d -s "${TMUX}uninitialized"
    rm "$TMUX_CONF"

    local LINE=$(tmux -S $TMUX_SOCKET ls |grep -P "^${TMUX}uninitialized:")
    if [ "$LINE" = "" ]; then
        echo "Failed!"
	return 1
    else
        echo "Started!"
        return 0
    fi
}
function tmux_stop() {
    if tmux_running; then  
       tmux -S $TMUX_SOCKET kill-session -t $TMUX
    fi
}
# Send a string to STDIN, for sending commands to the server.
function tmux_cmd() {
    if [ -z $4 ]; then
	local LOGFILE="$SERVER_LOG"
    else
	local LOGFILE="$4"
    fi

    tmux -S $TMUX_SOCKET send-keys -t $TMUX "`printf "$1\r"`"
    if [ ! -z "$2" ]; then
	if [[ ! -f $LOGFILE ]]; then
	    local START_LINE=0
	else
	    local START_LINE=`cat "$LOGFILE" |wc -l`
	fi

	if [ ! -z "$3" ]; then
	    SLEPT=0
	    while  [[ $SLEPT -le $2 ]]; do
		#renew lock
		if ! extend_lock; then
		    echo "Command failed: $1"
		    return 1
		fi

		for SUBSLEEP in {1..5}; do
		    if tmux_log_find_regexp "$3" "$LOGFILE" $START_LINE; then
			return 0
		    fi
		    sleep 0.2
		done

		SLEPT=`expr $SLEPT +  1`
	    done
	    echo "Command failed: $1"
	    return 1
	else
	    sleep "$2"
	fi
    fi

    return 0
}

function tmux_log_find_regexp() {
    local OFFSET=`expr "$3" + 1`
    local FOUND=`tail -n +$OFFSET "$LOGFILE" | grep -P "$1"`
    #local AAA=`tail -n +$OFFSET "$LOGFILE"|wc -l`
    #echo "tail length $AAA; FOUND is '$FOUND'"

    if [ -z "$FOUND" ]; then
	return 1
    else
	return 0
    fi
}

function server_pid_remove() {
    if [ -f $PATH_MINECRAFT_PID ]; then
        rm -f $PATH_MINECRAFT_PID
    fi
}
function server_start() {
    if is_server_online; then
        echo -e "Minecraft server is already \033[1;32monline\033[0m"
        return 0
    fi
    if tmux_running; then
	#There is no such thing as a valid leftover shell session,
	#since the main command end with ...;exit
	tmux_stop
    fi

    #Until we have stuffed the "...;exit" into the tmux session,
    #there is a teoretical race security hole, where the tmux
    #session is a full-featured shell. If someone can inject the
    #correct command via fx a minecraft talk command in that small
    #time window, they can execute shell commands.
    #
    #Hence we give the uninitialized tmux session a special name
    #until it is initialized and made safe with the "...; exit"
    #command
    TMUX_TMP=$TMUX
    TMUX="${TMUX}uninitialized"
    if tmux_running; then
	#remove any leftover ...uninitialized session
	tmux_stop
    fi

    if ! tmux_start; then
	TMUX=$TMUX_TMP
        return 1
    fi

    echo -n "Starting Minecraft server... "

    #use timestamp for saving server start time.
    TMP_TIMESTAMP_FILE=`mktemp`

    tmux_cmd "script -f -a $TMUX_LOG; exit"
    tmux_cmd "cd ${PATH_RUN}"
    #note arg 5 - starting a new server will reset the log, so tell tmux_cmd to always start from line 0
    #If I don't put the extra Ms on "Minecraft is stopped", then the first "M" goes missing in the output. WTF?
    tmux_cmd "sudo ${SERVER} & echo \$! | sudo tee ${PATH_MINECRAFT_PID} && fg; echo \"MMMMinecraft is stopped\"; exit" 30 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:|\>\cM\[\d\d:\d\d:\d\d\ INFO\]:) Done \(\d+.\d+s\)! For help, type "help" or "\?"' $TMUX_LOG
    
    #tmux now securely initialized! Rename to real name
    tmux -S $TMUX_SOCKET rename-session -t $TMUX $TMUX_TMP
    TMUX="$TMUX_TMP"

    if is_server_online; then
	echo "Started!"
	if $USE_SAVEOFF; then
            tmux_cmd "save-off"
	fi

	#wait for the new log file to actually be written to.
	#This seems to happen with some delay, which can confuse this script
	#If nothing happens within 10 seconds, then continue anyway
        for SUBSLEEP in {1..100}; do
	    if [ "$SERVER_LOG" -nt "$TMP_TIMESTAMP_FILE" ]; then
		break;
	    fi
	    sleep 0.1
	done

	rm $TMP_TIMESTAMP_FILE
        return 0
    else
        echo "Failed!"
        #remove hanging java processes
	tmux_stop
	echo "Failed to start server after ${MAX_ATTEMPTS} attempts"
	cat /logmc.txt
	rm $TMP_TIMESTAMP_FILE
	return 1
    fi
}
function server_stop() {
    if ! is_server_online; then
        echo -e "Minecraft server is already \033[1;31moffline\033[0m"
        return 0
    fi

    tmux_cmd "say Server going down! Saving world..."
    if ! server_save; then
	echo "Save failed, so refusing to stop server"
	return 1
    fi

    echo -n "Stopping Minecraft server ... "
    if ! tmux_cmd "stop" 60 '^(\>\s*)*(\c[\[m)?M+inecraft is stopped' "$TMUX_LOG"; then
	echo "Failed to stop server"
	return 1	
    fi

    if ! is_server_online; then
        echo "Stopped!"
        server_pid_remove
	tmux_stop
        return 0
    else
	echo "Failed to stop server"
	return 1
    fi
}
function server_stop_nosave() {
    if ! is_server_online; then
        echo -e "Minecraft server is already \033[1;31moffline\033[0m"
        return 0
    fi

    echo -n "Stopping Minecraft server... "

    tmux_cmd "stop" 60 '^(\>\s*)*(\c[\[m)?M+inecraft is stopped' "$TMUX_LOG"

    if ! is_server_online; then
        echo "Stopped!"
        server_pid_remove
        if tmux_running; then
	    tmux_stop
	fi
        return 0
    else
        echo "Failed!"
    fi

    return 1
}

function server_reload() {
        if ! is_server_online; then
	    echo "Server is offline, so can't reload."
	    return 1
        fi

        if tmux_cmd "reload" 10 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) CONSOLE: (.\[0;32;1m)?Reload complete\.(\[m)?'; then
	    return 0
	else
	    echo "Failed to reload within 10 seconds, got tired of waiting."
	    return 1
	fi
}

#helper for get_java_pid
function get_first_java_pid() {
    local PIDS=$(ps --ppid $1 -o pid h |awk '{print $1}')
    while read -r line; do
	echo "checking -->$line<--"
	if [ "$line" == "" ]; then
	    continue
	fi

	#is this pid the java command?
	local CHECK_PID_COMMAND=$(ps --pid $line -o command h)
        #sanity check that the process is indeed java
        #spaces are collapsed in the proc command line
	local SERVER2=$(echo "$SERVER"|sed 's/  / /g')
	if [ "$SERVER2" == "$CHECK_PID_COMMAND" ]; then
	    FIRST_JAVA_PID="$line"
	    return 0;
	fi

	#is a child the java command?
	if get_first_java_pid $line; then
	    return 0
	fi
    done <<< "$PIDS"

    return 1;
}

function get_java_pid() {
    if ! tmux_running; then
	echo "Couldn't find tmux, so java presumably not running.";
	return 1;
    fi

    if ! get_tmux_pid; then
	echo "failed to find tmux pid.";
	return 1;
    fi

    if get_first_java_pid $TMUX_PID; then
        #FIRST_JAVA_PID is now set ()
	JAVA_PID="$FIRST_JAVA_PID"
    else
	echo "Failed to find the pid of java, so minecraft is presumably not running.";
	JAVA_PID=-1
	return 1;
    fi

    return 0;
}

function kill_minecraft() {
    if ! get_java_pid; then
	return 1
    fi

    echo "Sending kill signal to first java process... "

    local ATTEMPTS=10
    local ITER=1
    while [ $ITER -le $ATTEMPTS ]; do
	kill $JAVA_PID
        sleep 1
	if ! get_java_pid; then
	    echo "Minecraft process seems to have been killed!"
	    if tmux_running; then
		tmux_stop
	    fi
	    return 0;
	else
            echo "Failed!"
            let ITER=$ITER+1
	fi
    done

    echo "Failed to kill minecraft process. Try nuking it"
    return 1
}

function nuke() {
    if ! get_tmux_pid; then
	return 1
    fi
    #TMUX_PID is now set

    local ATTEMPTS=10
    local ITER=1
    while [ $ITER -le $ATTEMPTS ]; do
	echo "Sending kill -9 to minecraft parent process..."
	kill -9 $TMUX_PID
	echo "Kill command sent!"
        sleep 1
	if ! get_tmux_pid; then
	    echo "Minecraft parent process seems to have been nuked!"
	    if tmux_running; then
		tmux_stop
	    fi
	    return 0;
	else
            echo "Failed!"
            let ITER=$ITER+1
	fi
    done

    echo "Failed to nuke minecraft parent process. This really shouldn't happen. Ask Thue for help."
    return 1
}

function is_map_dir() {
   if [ -f "$1/level.dat" ]; then
      return 0;
   else
      return 1;
   fi
}

function delete_map() {
    rm -f "${PATH_RUN}"/rfwadmin_*

    for file in ${PATH_RUN}/*; do
      if is_map_dir "$file"; then
	rm -rf "$file"
      fi
    done
}

function delete_conf() {
    #Delete plugin config
    find . -maxdepth 1 -not -name \*.jar -not -name . -type d -exec rm -r '{}' \;
}

function change_map() {
    WAS_ONLINE=0
    if is_server_online; then
       WAS_ONLINE=1
       server_stop_nosave;
    fi

    #world_nether and world_the_end are created by bukkit
    echo -n "Deleting old map... "
    delete_map
    echo "Deleted!"
    echo -n "Installing new map... "
    if is_map_dir "${MAP_DIR}/$1"; then
      cp -rp "${MAP_DIR}"/"$1" "${PATH_RUN}/world"
    else
      cp -rp "${MAP_DIR}"/"$1"/* "${PATH_RUN}"
    fi
    echo -n "$1" > "${PATH_RUN}"/rfwadmin_map_full_name

    #set level seed if possible
    if [ -f "${MAP_DIR}/$1/rfwadmin_map_level-seed" ]; then
	LEVEL_SEED=`cat "${MAP_DIR}/$1/rfwadmin_map_level-seed"|head -n 1`
	cat "${PATH_RUN}/server.properties" |grep -v "^level-seed=" > "${PATH_RUN}/server.properties.tmp"
	echo -e "\\n" >> "${PATH_RUN}/server.properties.tmp"
	echo "level-seed=$LEVEL_SEED" >> "${PATH_RUN}/server.properties.tmp"
	mv -f "${PATH_RUN}/server.properties.tmp" "${PATH_RUN}/server.properties"
    fi

    echo "Installed!"

    if [ $WAS_ONLINE -eq 1 ]; then
       server_start;
    else
       echo "New map loaded. Server was not started, as it was not running before the map change."
    fi
}
function server_save() {
    if ! is_server_online; then
        echo -e "Minecraft server is \033[1;32moffline\033[0m"
        return 0
    fi

    echo -n "Saving world... "
    if $USE_SAVEOFF; then
	tmux_cmd "save-on"   10 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) CONSOLE: Enabling level saving..'
    fi

    if ! tmux_cmd "save-all" 30 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) (CONSOLE: Save complete.|Saved the world)'; then
	echo "Save failed!";
	return 1
    fi

    if [ "`echo "$SERVER_LOG" | grep -P 'logs/latest.log$'`" == "" ]; then
	echo -n "(Running save-all 2 more times and sleeping 10 seconds because of Minecraft bug MC-2527)... "
	sleep 3
	tmux_cmd "save-all" 30 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) (CONSOLE: Save complete.|Saved the world)'
	sleep 3
	tmux_cmd "save-all" 30 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) (CONSOLE: Save complete.|Saved the world)'
	sleep 4
    fi

    if $USE_SAVEOFF; then
	tmux_cmd "save-off"  10 '^(\d\d\d\d-\d\d-\d\d \d\d:\d\d:\d\d \[INFO\]|\[\d\d:\d\d:\d\d\] \[Server thread/INFO\]:) CONSOLE: Disabling level saving..'
    fi
    echo "Saved!"
    return 0;
}
function server_backup() {
    if is_server_online; then
        tmux_cmd "say Saving new backup..."
        server_save
    fi

    pushd $PATH_RUN > /dev/null

    rm -rf "$PATH_BACKUP/world"
    cp -rp $WORLD "$PATH_BACKUP/world"
    tar czf "$PATH_BACKUP/`date +'%F_%H:%M'`.tar.gz" $WORLD
    popd > /dev/null

    if is_server_online; then
        tmux_cmd "say Backup completed!"
    fi
    return 0
}
function server_backup_safe() {
    if is_server_online; then
        tmux_cmd "say Serving going down for safe backup..."
        if ! server_stop; then
	    unlock
            exit 1
        fi
        local WAS_ONLINE=1
    else
        local WAS_ONLINE=0
    fi

    server_backup

    if [ $WAS_ONLINE -eq 1 ]; then
        server_start
    fi
}

function upgrade() {
    wget https://s3.amazonaws.com/MinecraftDownload/launcher/minecraft_server.jar -O "${PATH_SERVER}/minecraft_server.jar.tmp" || die "failed to download https://s3.amazonaws.com/MinecraftDownload/launcher/minecraft_server.jar"
    mv "${PATH_SERVER}/minecraft_server.jar.tmp" "${PATH_RUN}/minecraft_server.jar"
}

function get_cmdline() {
    #The sed replaces is to replace null chars with spaces and to quote arguments
    #                        rm trailing ns     handle first n     handle middle ns  handle last n
    CMDLINE=`cat "/proc/$$/cmdline" | sed 's/\x0\+$//' | sed 's/\x0/ "/'  | sed 's/\x0/" "/g'| sed 's/$/"/'`
}

function lock_timed_out() {
    FILE_CREATION_TIME=`stat -c %Y "$LOCKFILE"`
    TIME_NOW=`date +%s`
    if (( $TIME_NOW - $FILE_CREATION_TIME > $LOCK_FILE_TIMEOUT )); then 
	return 0;
    else
	return 1;
    fi
}

function lock() {
    #Generate lockfile contents. For some reason I can't just do 'echo -e "$$\n$CMDLINE"'
    TMP=`mktemp`
    echo "$$" >> $TMP
    get_cmdline
    echo $CMDLINE >> $TMP

    #Try to actually aquire lock
    set +e
    SUCCESS=`(cat $TMP > "${LOCKFILE}") 2>&1`
    set -e
    rm $TMP

    REMOVED_STALE=0

    if [ "$SUCCESS" != "" ]; then
	if lock_timed_out; then 
	    echo -n "There is an existing lockfile, but it is timed out. Removing... "
	    if unlock 1; then
		REMOVED_STALE=1
		echo "Stale lockfile removed!"
		if lock $1; then
		    return 0;
		else
		    return 1
		fi
	    else
		echo "Failed to remove stale lockfile!"
		return 1
	    fi
	else 
	    if [ "$1" == 1 ]; then
		#Format for "status" command
		cat "${LOCKFILE}" | tail -n +2
	    else
		echo "Another process is currently running the server control script - aborting. The other process is:";
		cat "${LOCKFILE}" | tail -n +2
	    fi
	    return 1
	fi
    else
	return 0
    fi
}

function unlock() {
    if [ "$1" == "1" ]; then
	#remove time out lockfile
	if ! lock_timed_out; then
	    echo "The current lock file isn't timed out, so not removing!"
	    return 1;
	else
	    if ! lock2; then
		echo "unable to lock the lock file!"
		return 1
	    fi
	    rm "$LOCKFILE"
	    unlock2
	    return 0
	fi
    else
	if ! lock2; then
	    echo "failed to lock the lock file"
	    return 1
	fi
	get_lockfile_pid
	if [ "$LOCKFILE_PID" == "$$" ]; then
	    rm "$LOCKFILE"
	else
	    echo "lockfile doesn't belong to current process - refusing to delete"
	fi

	unlock2
    fi
}

function extend_lock() {
    if lock2; then
	get_lockfile_pid
	if [ "$LOCKFILE_PID" == "$$" ]; then
	    TMP=`mktemp`
	    echo "$$" >> $TMP
	    get_cmdline
	    echo $CMDLINE >> $TMP
	    chmod go+r "${LOCKFILE}"
	    mv "$TMP" "${LOCKFILE}"
	else
	    echo "lockfile doesn't belong to current process - refusing to delete"
	    unlock2
	    return 1
	fi	
	unlock2
	return 0
    fi
    echo "Failed to extend lock!"
    return 1
}

function get_lockfile_pid() {
    LOCKFILE_PID=`cat "$LOCKFILE" |head -n 1`
}

#lock2 is taken while removing lockfiles.  The code inside lock2 is
#simple enough that we don't have to worry about dying inside (unlike
#lock1), so it is not just kicking the ball down the road.
function lock2() {
    TMP=`mktemp`
    echo "$$" >> $TMP
    get_cmdline
    echo $CMDLINE >> $TMP
    set +e
    LOCK2=`cat "$TMP" > "$LOCKFILE2"`
    set -e
    rm $TMP
    if [ "$LOCK2" == "" ]; then
	return 0
    else
	return 1
    fi
}
function unlock2() {
    rm "$LOCKFILE2"
}

function force_unlock() {
    rm -f "$LOCKFILE"
    rm -f "$LOCKFILE2"
}

function convert() {
    echo java -Xms${MEM_LOW} -Xmx${MEM_HIGH} -jar "$PATH_BASE/jars/converter/AnvilConverter.jar" "$PATH_BASE/maps/" "$1"
    java -Xms${MEM_LOW} -Xmx${MEM_HIGH} -jar "$PATH_BASE/jars/converter/AnvilConverter.jar" "$PATH_BASE/maps/" "$1"
}

#Special case status, since that must run even if locking fails
if [ "$1" == "status" ]; then
    set +e
    LOCK_OUTPUT=`lock 1`
    LOCK_RES=`echo $?`
    set -e
    if [ 1 -eq $LOCK_RES ]; then
	echo -en "Minecraft server is \033[0;33mrunning a command\033[0m"
	echo " (${LOCK_OUTPUT})"
    else
	if is_server_online; then
            echo -e "Minecraft server is \033[1;32monline\033[0m"
	else
            echo -e "Minecraft server is \033[1;31moffline\033[0m"
	fi
	unlock
    fi
    exit 0
fi

if [ "$SERVER_LOG" == "" ]; then
    set_server_log
fi

if [ "$1" == "logfile_path" ]; then
    echo $SERVER_LOG;
    exit 0;
fi

#Make a big lock around everything. You must call unlock before exiting.
if ! lock; then
    echo failed to lock!
    exit 1
fi

case $1 in
    start)
        if ! server_start; then
	    unlock
            exit 1
        fi
        ;;
    stop)
        if is_server_online; then
            tmux_cmd "say Server shutting down..."
            if ! server_stop; then
		unlock
                exit 1
            fi
        else
            echo -e "Minecraft server is already \033[1;31moffline\033[0m"
        fi
        ;;
    stop_nosave)
        if is_server_online; then
            tmux_cmd "say Server shutting down..."
            if ! server_stop_nosave; then
		unlock
                exit 1
            fi
        else
            echo -e "Minecraft server is already \033[1;31moffline\033[0m"
        fi
	;;
    restart)
        if is_server_online; then
            tmux_cmd "say Server restarting..."
            if server_stop; then
		server_start
	    else
		echo "Failed to stop server!"
	    fi
        else
            server_start
        fi
        ;;
    kill)
	if kill_minecraft; then
	    unlock
	    exit 0
	else
	    unlock
	    exit 1
	fi
	;;
    nuke)
	if nuke; then
	    unlock;
	    exit 0
	else
	    unlock
	    exit 1
	fi
	;;
    delete_map)
        if is_server_online; then
            if ! server_stop; then
		echo "Failed to stop server!";
		exit 1;
	    fi
	fi
	delete_map
	;;
    nuke_and_delete)
	if nuke; then
	    delete_map
	    echo "Map has been deleted!"
	    #delete_conf
	    #echo "Plugin configuration has been deleted!"
	    echo "Done nuking, and deleting! "
	fi
	;;
    changemap)
        change_map "$2"
        ;;
    reload|force-reload)
	if ! server_reload; then
	    unlock
	    exit 1;
	fi
        ;;
    send_command)
        send_command "$2"
        ;;
    list)
	if list; then
	    echo $LIST_LINE
	else
	    unlock
	    exit 1
	fi
	;;
    unlock)
	force_unlock
	;;
    save)
        server_save
        ;;
    backup)
        server_backup
        ;;
    safe-backup)
        server_backup_safe
        ;;
    convert)
	convert "$2"
	;;
    upgrade)
        if is_server_online; then
            server_stop
	    upgrade
	    server_start
	else
	    upgrade
	fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|reload|backup|safe-backup}"
        ;;
esac

unlock
exit 0
